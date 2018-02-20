{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

module General.Chunks(
    Chunks,
    readChunk, readChunkMax, writeChunks, writeChunk,
    restoreChunksBackup, withChunks, resetChunksCompact, resetChunksCorrupt
    ) where

import System.Time.Extra
import System.FilePath
import Control.Concurrent.Extra
import Control.Monad.Extra
import Control.Exception
import System.IO
import System.Directory
import qualified Data.ByteString as BS
import Data.Word
import Data.Monoid
import General.Binary
import General.Extra
import Prelude


data Chunks = Chunks
    {chunksFileName :: FilePath
    ,chunksFlush :: Maybe Seconds
    ,chunksHandle :: MVar Handle
    }


---------------------------------------------------------------------
-- READ/WRITE OPERATIONS

readChunk :: Chunks -> IO (Either BS.ByteString BS.ByteString)
readChunk c = readChunkMax c maxBound

-- | Return either a valid chunk (Right), or a trailing suffix with no information (Left)
readChunkMax :: Chunks -> Word32 -> IO (Either BS.ByteString BS.ByteString)
readChunkMax Chunks{..} mx = withMVar chunksHandle $ \h -> do
    let slop x = do
            unless (BS.null x) $ hSetFileSize h . subtract (toInteger $ BS.length x) =<< hFileSize h
            return $ Left x
    n <- BS.hGet h 4
    if BS.length n < 4 then slop n else do
        let count = fromIntegral $ min mx $ fst $ unsafeBinarySplit n
        v <- BS.hGet h count
        if BS.length v < count then slop (n `BS.append` v) else return $ Right v

writeChunkDirect :: Handle -> Builder -> IO ()
writeChunkDirect h x = bs `seq` BS.hPut h bs
    where bs = runBuilder $ putEx (fromIntegral $ sizeBuilder x :: Word32) <> x


-- | If 'writeChunks' and any of the reopen operations are interleaved it will cause issues.
writeChunks :: Chunks -> ((Builder -> IO ()) -> IO a) -> IO a
-- We avoid calling flush too often on SSD drives, as that can be slow
-- Make sure all exceptions happen on the caller, so we don't have to move exceptions back
-- Make sure we only write on one thread, otherwise async exceptions can cause partial writes
writeChunks Chunks{..} act = withMVar chunksHandle $ \h -> do
    chan <- newChan -- operations to perform on the file
    kick <- newEmptyMVar -- kicked whenever something is written
    died <- newBarrier -- has the writing thread finished

    flusher <- case chunksFlush of
        Nothing -> return Nothing
        Just flush -> fmap Just $ forkIO $ forever $ do
            takeMVar kick
            threadDelay $ ceiling $ flush * 1000000
            tryTakeMVar kick
            writeChan chan $ hFlush h >> return True

    root <- myThreadId
    writer <- flip forkFinally (\e -> do signalBarrier died (); whenLeft e (throwTo root)) $
        -- only one thread ever writes, ensuring only the final write can be torn
        whileM $ join $ readChan chan

    (act $ \s -> do
            out <- evaluate $ writeChunkDirect h s -- ensure exceptions occur on this thread
            writeChan chan $ out >> tryPutMVar kick () >> return True)
        `finally` do
            maybe (return ()) killThread flusher
            writeChan chan $ return False
            waitBarrier died

writeChunk :: Chunks -> Builder -> IO ()
writeChunk Chunks{..} x = withMVar chunksHandle $ \h -> writeChunkDirect h x


---------------------------------------------------------------------
-- FILENAME OPERATIONS

backup x = x <.> "backup"

restoreChunksBackup :: FilePath -> IO Bool
restoreChunksBackup file = do
    -- complete a partially failed compress
    b <- doesFileExist $ backup file
    if not b then return False else do
        removeFile_ file
        renameFile (backup file) file
        return True


withChunks :: FilePath -> Maybe Seconds -> (Chunks -> IO a) -> IO a
withChunks file flush act = do
    h <- newEmptyMVar
    bracket_
        (putMVar h =<< openFile file ReadWriteMode)
        (hClose =<< takeMVar h) $
        act $ Chunks file flush h


-- | The file is being compacted, if the process fails, use a backup.
resetChunksCompact :: Chunks -> ((Builder -> IO ()) -> IO a) -> IO a
resetChunksCompact Chunks{..} act = mask $ \restore -> do
    h <- takeMVar chunksHandle
    flip onException (putMVar chunksHandle h) $ restore $ do
        hClose h
        copyFile chunksFileName $ backup chunksFileName
    h <- openFile chunksFileName ReadWriteMode
    flip finally (putMVar chunksHandle h) $ restore $ do
        hSetFileSize h 0
        hSeek h AbsoluteSeek 0
        res <- act $ writeChunkDirect h
        hFlush h
        removeFile $ backup chunksFileName
        return res


-- | The file got corrupted, return a new version.
resetChunksCorrupt :: Maybe FilePath -> Chunks -> IO ()
resetChunksCorrupt copy Chunks{..} = mask $ \restore -> do
    h <- takeMVar chunksHandle
    case copy of
        Nothing -> return h
        Just copy -> do
            flip onException (putMVar chunksHandle h) $ restore $ do
                hClose h
                copyFile chunksFileName copy
            openFile chunksFileName ReadWriteMode
    flip finally (putMVar chunksHandle h) $ do
        hSetFileSize h 0
        hSeek h AbsoluteSeek 0
