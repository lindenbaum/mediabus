module Data.MediaBus.Transport.Udp (udpDatagramSource) where

import Conduit
import Control.Lens
import Control.Monad.State.Strict
import qualified Data.ByteString as B
import Data.Conduit.Network.UDP
import Data.Default
import Data.MediaBus.Basics.Clock
import Data.MediaBus.Basics.Sequence
import Data.MediaBus.Basics.SourceId
import Data.MediaBus.Conduit.Stream
import Data.MediaBus.Media.Stream
import Data.Streaming.Network
import Network.Socket (SockAddr, close)

-- | A UDP source that uses 'MonandResource' to make sure the socket is closed.
udpDatagramSource ::
  (IsClock c, MonadClock c m, MonadResource m, Num s, Default p) =>
  proxy c ->
  Int ->
  HostPreference ->
  ConduitT () (Stream (SourceId (Maybe SockAddr)) (SeqNum s) (ClockTimeDiff c) p B.ByteString) m ()
udpDatagramSource _clk port host = do
  !t0 <- lift now
  bracketP (bindPortUDP port host) close (`sourceSocket` 1024)
    .| evalStateC (Nothing, 0, t0) (awaitForever createFrame)
  where
    createFrame m = do
      let currentSender = msgSender m
      lastSender <- _1 <<.= Just currentSender
      tNow <- lift (lift now)
      when (Just currentSender /= lastSender) $ do
        _2 .= 0
        _3 .= tNow
        yieldStartFrameCtx
          ( MkFrameCtx
              (MkSourceId (Just currentSender))
              (timeAsTimeDiff tNow)
              0
              def
          )
      sn <- _2 <<+= 1
      tStart <- use _3
      yieldNextFrame (MkFrame (diffTime tNow tStart) sn (msgData m))
