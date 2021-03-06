-- | Asynchronous execution of conduits. This module contains a set of functions
-- to concurrently execute 'Stream' processing conduits and couple them using
-- 'TBQueue's.
module Data.MediaBus.Conduit.FrameRing
  ( FrameRing (),

    mkFrameRing,
    frameRingSink,
    frameRingSource,
  )
where

import Conduit
import Control.Concurrent (threadDelay)
import Control.Lens
import Control.Monad.Logger
import Control.Monad.State
import Control.Parallel.Strategies
  ( NFData,
    rdeepseq,
    withStrategy,
  )
import Data.Default
import Data.MediaBus.Basics.Clock
import Data.MediaBus.Basics.Sequence
import Data.MediaBus.Basics.Ticks
import Data.MediaBus.Conduit.Stream
import Data.MediaBus.Media.Discontinous
import Data.MediaBus.Media.SyncStream
import Data.MediaBus.Media.Stream
import Data.Proxy
import Data.String
import Data.Time.Clock
import Numeric.Natural
import System.Random
import Text.Printf
import UnliftIO

data RingSourceState s t
  = MkRingSourceState
      { _timeSinceLastInput :: !NominalDiffTime,
        _undeflowReported :: !Bool
      }

makeLenses ''RingSourceState

-- | A ring like queue, to provide a constant flow of frames.
--
-- This helps to decouple concurrent conduits carrying
-- 'Stream's.
--
-- The implementation uses bounded queues 'TBQueue'.
--
-- The internal queue can be filled from one thread and consumed by
-- another thread.
--
-- Refer to 'frameRingSink' to learn howto put data into the ring
-- and 'frameRingSource' on how to retreive data.
newtype FrameRing i p c
  = MkFrameRing
      { _frameRingTBQueue :: TBQueue (Streamish i () () p (FrameRingPayload c))
      }


data FrameRingPayload c =
    FrameRingPayload {frameRingPayload :: c}
  | FrameRingOverflow {lostPayload :: c, frameRingPayload :: c}

-- | Create a new 'FrameRing' with an upper bound on the queue length.
mkFrameRing ::
  (MonadIO m) =>
  Natural ->
  -- ^ Ring Element Count
  m (FrameRing i p c)
mkFrameRing qlen =
  MkFrameRing <$> newTBQueueIO qlen

-- | Consume the 'Frame's of a 'Stream' and write them into a
-- 'FrameRing'. When the queue is full, **drop the oldest element** and push
-- in the new element, anyway.
frameRingSink ::
  (NFData c,
  MonadIO m) =>
  FrameRing i p c ->
  ConduitT (SyncStream i p c) Void m ()
frameRingSink (MkFrameRing !ringRef) = awaitForever go
  where
    go !x = do
      maybe (return ()) pushInRing (x ^? eachFramePayload)
      return ()
      where
        pushInRing !buf' = do
          !buf <- evaluate $ withStrategy rdeepseq buf'
          atomically $ do
            isFull <- isFullTBQueue ringRef
            frpBuf <-
              if isFull then

                (\lostFrame ->
                  case lostFrame of
                    FrameRingPayload lostBuf ->
                      FrameRingOverflow lostBuf buf
                    FrameRingOverflow lostBuf2 lostBuf ->
                      FrameRingOverflow lostBuf buf

                )

                <$> readTBQueue ringRef
              else
                return (FrameRingPayload buf)
            writeTBQueue ringRef frpBuf

-- | Periodically poll a 'FrameRing' and yield the 'Frame's
-- put into the ring, or 'Missing' otherwise.
--
-- When after
frameRingSource ::
  ( MonadIO m ) =>
  FrameRing i p c ->
  NominalDiffTime ->
  ConduitT () (SyncStream i p (Discontinous a)) m ()
  --  TODO ConduitT () (Stream i s (Ticks r t) p (AnnotatedFrame (Maybe FrameRingEvent) (Discontinous c))) m ()
frameRingSource  (MkFrameRing ringRef) pTime =
  evalStateC (MkRingSourceState 0 True) $ do
    yieldStart
    go
  where
    pTime = getStaticDuration (Proxy @a)
    -- TODO this breaks when 'frameRingPollInterval < duration c'?
    --      to fix add a 'timePassedSinceLastBufferReceived' parameter to 'go'
    --      when no new from could be read from the queue after waiting for 'dt'
    --      seconds, the time waited is added to 'frameRingPollInterval'
    --      and if 'frameRingPollIntervall' is greater than the 'duration of c'
    --      a 'Missing' is yielded and 'duration of c' is subtracted from
    --      'timePassedSinceLastBufferReceived'.
    go = do
      res <- liftIO $ race (atomically $ readTBQueue ringRef) sleep
      case res of
        Left buf -> do
          yieldNextBuffer (Got buf)
        Right dt -> do
          t <- timeSinceLastInput <<+= dt
          when (pTime < t) yieldMissing
      go

    sleep =
      liftIO
        ( do
            !(t0 :: ClockTime UtcClock) <- now
            threadDelay (_ticks pollIntervallMicros)
            !t1 <- now
            return (diffTime t1 t0 ^. utcClockTimeDiff)
        )
        where
          pollIntervallMicros :: Ticks (Hz 1000000) Int
          pollIntervallMicros = nominalDiffTime # pollIntervall

    yieldStart =
      ( MkFrameCtx
          <$> liftIO randomIO
          <*> use currentTicks
          <*> use currentSeqNum
          <*> pure def
      )
        >>= yieldStartFrameCtx

    yieldNextBuffer !buf = do
      let !bufferDuration = nominalDiffTime # getDuration buf
      !ts <- currentTicks <<+= bufferDuration
      !sn <- currentSeqNum <<+= 1
      frm <- evaluate (withStrategy rdeepseq $ MkFrame ts sn buf)
      yieldNextFrame frm


    yieldMissing = do
      t <- use timeSinceLastInput
      when (pTime < t) $ do
        timeSinceLastInput -= pTime
        yieldNextBuffer Missing
