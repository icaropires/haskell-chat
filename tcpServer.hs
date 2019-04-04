
{-# LANGUAGE RecordWildCards #-}
module Main where

import Text.Printf
import System.IO
import Network
import qualified Data.Map as Map
import Data.Map (Map)
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import System.Environment

main :: IO ()
main = withSocketsDo $ do
  server <- newServer
  args <- getArgs
  let port = fromIntegral (read $ head args :: Int)
  sock <- listenOn (PortNumber port)
  printf "Chat server started on port: %s\n" (show port)
  forever $ do
      (handle, host, port) <- accept sock
      printf "Connection %s: %s\n" host (show port)
      forkFinally (talk handle server) (\_ -> hClose handle)

-- Data structures and initialisation

--Client
type ClientName = String

data Client = Client
  { clientName     :: ClientName
  , clientHandle   :: Handle
  , clientSendChan :: TChan Message
  }

--newClient
newClient :: ClientName -> Handle -> STM Client
newClient name handle = do
  c <- newTChan
  k <- newTVar Nothing
  return Client { clientName     = name
                , clientHandle   = handle
                , clientSendChan = c
                }

--Server
data Server = Server
  { clients :: TVar (Map ClientName Client)
  }

newServer :: IO Server
newServer = do
  c <- newTVarIO Map.empty
  return Server { clients = c }


--Message
data Message = Notice String
             | Tell ClientName String
             | Broadcast ClientName String
             | Command String

--broadcast
broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg = do
  clientmap <- readTVar clients
  mapM_ (\client -> sendMessage client msg) (Map.elems clientmap)

-- <<sendMessage
sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg =
  writeTChan clientSendChan msg


--Server handling

talk :: Handle -> Server -> IO ()
talk handle server@Server{..} = do
  hSetNewlineMode handle universalNewlineMode
      -- Swallow carriage returns sent by telnet clients
  hSetBuffering handle LineBuffering
  readName
 where
--readName
  readName = do
    hPutStrLn handle "Please enter username"
    name <- hGetLine handle
    if null name
      then readName
      else mask $ \restore -> do        -- <1>
             ok <- checkAddClient server name handle
             case ok of
               Nothing -> restore $ do  -- <2>
                  hPrintf handle
                     "Name %s is in use please choose different username\n" name
                  readName
               Just client ->
                  restore (runClient server client) -- <3>
                      `finally` removeClient server name

--checkAddClient
checkAddClient :: Server -> ClientName -> Handle -> IO (Maybe Client)
checkAddClient server@Server{..} name handle = atomically $ do
  clientmap <- readTVar clients
  if Map.member name clientmap
    then return Nothing
    else do client <- newClient name handle
            writeTVar clients $ Map.insert name client clientmap
            broadcast server  $ Notice (name ++ " joined")
            return (Just client)

--removeClient
removeClient :: Server -> ClientName -> IO ()
removeClient server@Server{..} name = atomically $ do
  modifyTVar' clients $ Map.delete name
  broadcast server $ Notice (name ++ " left")

--runClient
runClient :: Server -> Client -> IO ()
runClient serv@Server{..} client@Client{..} = do
  race server receive
  return ()
 where
  receive = forever $ do
    msg <- hGetLine clientHandle
    atomically $ sendMessage client (Command msg)

  server = join $ atomically $ do
   msg <- readTChan clientSendChan
   return $ do
     continue <- handleMessage serv client msg
     when continue $ server

--handleMessage different type of message
handleMessage :: Server -> Client -> Message -> IO Bool
handleMessage server client@Client{..} message =
  case message of
     Notice msg         -> output $ "*** " ++ msg
     Broadcast name msg -> output $ name ++ ": " ++ msg
     Command msg ->
       case words msg of
           ["KILL_SERVICE"] ->
               return False
           _ -> do
               atomically $ broadcast server $ Broadcast clientName msg
               return True
 where
   output s = do hPutStrLn clientHandle s; return True
