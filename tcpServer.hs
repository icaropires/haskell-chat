
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

main :: IO () -- Função principal do módulo Main
main = withSocketsDo $ do -- Inicializar subsistema de rede em SO windows
  server <- newServer -- Chama função newServer, devolvendo um Servidor criado
  args <- getArgs -- Pega os argumentos passados como argumento na execução do programa
  let port = fromIntegral (read $ head args :: Int) -- read: Pega bloco de coisa e transforma em valor
                                                    -- | head args:Pega primeiro argumento de args | :: Int - Converte para inteiro
                                                    -- | fromIntegral : transforma inteiro ou integer em tipo de número mais genérico (Ex: Somar float e int)
  sock <- listenOn (PortNumber port) -- Salva em sock o retorno de listenOn, passando número da porta (O retorno é um socket (IO Socket - listening socket))
                                     -- PortNumber : Tipo relativo a um num
  printf "Chat server started on port: %s\n" (show port) -- Imprime a porta que será utilizada
  forever $ do -- forever: Define um loop
    (handle, host, port) <- accept sock -- Aceita uma conexão ao socket
                                        -- Retorna o gerenciador de IO, número do host e a porta da conexão
      printf "Connection %s: %s\n" host (show port)
      forkFinally (talk handle server) (\_ -> hClose handle) -- Dá fork na thread e chama a função fornecida quando a thread está perto de finalizar
                                                             -- Ao finalizar uma "talk" (talk handle server), chama  (\_ -> hClose handle)
                                                             --  (\_ -> hClose handle) : Finaliza handle, se hdl for gravável, buffer é liberado para hflush

-- Data structures and initialisation

--Client
type ClientName = String

data Client = Client
  { clientName     :: ClientName -- Nome do cliente
  , clientHandle   :: Handle -- Gerenciamento de entradas e saídas
  , clientSendChan :: TChan Message -- Fila de mensagens
  }

--newClient
newClient :: ClientName -> Handle -> STM Client
newClient name handle = do -- Função que cria um novo cliente, recebe o nome e o handle (gerenciador de IO)
  c <- newTChan -- O Tchan representa uma FIFO, a função newTChan cria uma nova instância da FIFO e retorna para c
  k <- newTVar Nothing -- TVar são locais de memória compartilhada que suportam transações de memória atômica.
                       -- newTVar : Cria novo TVar vazio (Nothing)
  return Client { clientName     = name -- Função retorna um Client com nome, gerenciador IO e fila de mensagens dele
                , clientHandle   = handle
                , clientSendChan = c
                }

--Server
data Server = Server
  { clients :: TVar (Map ClientName Client) -- Server é composto por clients cuja estrutura consiste em local de memória compatilhada que
  }                                         -- contém o mapeamento dos nomes de todos os clientes?

newServer :: IO Server
newServer = do -- Função new server cria servidor e retorna-o
  c <- newTVarIO Map.empty -- Cria newTVarIO versão IO de TVar, vazio
  return Server { clients = c } -- Retorna servidor preenchido com esse TVar de clientes "vazio"


--Message
data Message = Notice String -- Mensagem do servidor
             | Tell ClientName String -- Mensagem privada de outro cliente
             | Broadcast ClientName String -- ? Mensagem de texto para vários clientes
             | Command String -- Linha de texto recebido do usuário

--broadcast
broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg = do -- Função broadcast que recebe os dados do servidor e a mensagem e envia a mensagem para todos os clientes no servidor
  clientmap <- readTVar clients -- readTVar : Recebe o Tvar clients definido previamente e retorna os valores armazenados no momento
  mapM_ (\client -> sendMessage client msg) (Map.elems clientmap) -- Para cada client em clientmap aplica a função sendMessage, enviando a Mensagem
                                                                  -- mapM_ : Ignora os retornos das funções

-- <<sendMessage
sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg = -- Função sendMessage recebe um Client com todos os atributos e a mensagem a ser enviada
  writeTChan clientSendChan msg -- Escreve na FIFO o cliente que tá mandando e a mensagem
                                -- Tchan é um tipo abstrato que representa uma FIFO ilimitada


--Server handling

talk :: Handle -> Server -> IO ()
talk handle server@Server{..} = do -- função talk recebe o handle e o servidor com lista de clientes,
                                   -- server@Server{..} nomeia todo o server com o apelido server
  hSetNewlineMode handle universalNewlineMode -- Configura modos de leitura (?) da linha como universal (usa o \n)
      -- Swallow carriage returns sent by telnet clients
  hSetBuffering handle LineBuffering -- Seta o buffer
  readName -- Chama função para ler o nome
 where
--readName
  readName = do -- Função readName lê o nome e autentica
    hPutStrLn handle "Please enter username" -- Imprime mensagem usando o gerente IO
    name <- hGetLine handle -- Lê o nome com o hGetLine
    if null name -- Se estiver vazio
      then readName -- Pede pra ler de novo
      else mask $ \restore -> do        -- <1> Senão (?) mask: Mascara excessões assíncronas tal que qualquer encadeamento que tente gerar excessão
                                        -- será bloqueado até que excessões assíncronas sejam desmascaradas
                                        -- o argumento de mask é uma função lambda \restore
             ok <- checkAddClient server name handle -- Chama a função checkAddClient para ver se já existe cliente com esse nome e guarda em ok
             case ok of -- se ok contiver Nothing, é porque o nome já existe
               Nothing -> restore $ do  -- <2> -- chama novamente restore
                  hPrintf handle
                     "Name %s is in use please choose different username\n" name --Printa mensagem
                  readName -- Lê novamente o nome
               Just client -> -- Só para client
                  restore (runClient server client) -- <3> Se o nome for aceito, desmascaramos as exceções assíncronas ao chamar runClient
                                                    -- passando o servidor e o cliente
                      `finally` removeClient server name -- Por fim, remove o cliente através de removeClient passando o servidor e o nome 

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
