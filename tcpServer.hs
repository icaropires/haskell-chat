
{-# LANGUAGE RecordWildCards #-}
module Main where

import Text.Printf
import System.IO
import Network
import qualified Data.Map as Map
import Data.Map (Map, size)
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
  allMessages <- newAllMessages -- Inicializa Tvar de mensagens


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
    forkFinally (talk handle server allMessages) (\_ -> hClose handle)  -- Dá fork na thread e chama a função fornecida quando a thread está perto de finalizar
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
                                            -- contém o mapeamento dos nomes de todos os clientes?
  }

--newServer

newServer :: IO Server
newServer = do -- Função new server cria servidor e retorna-o
  c <- newTVarIO Map.empty -- Cria newTVarIO versão IO de TVar, vazio
  return Server { clients = c } -- Retorna servidor preenchido com TVar de clientes "vazio"

--Message
data Message = Notice String -- Mensagem do servidor
             | Broadcast ClientName String String -- ? Mensagem de texto para vários clientes
             | Command String -- Linha de texto recebido do usuário
             | Reply ClientName String String -- Reply recebe o id da msg respondida e a msg de resposta
             | Message
             {
               idMessage :: String
               ,message :: Message
             }

data AllMessages = AllMessages
  { messages :: TVar (Map String Message) }

--newMessage

newAllMessages :: IO AllMessages
newAllMessages = do
  m <- newTVarIO Map.empty
  return AllMessages { messages = m }

newMessage :: Message -> String -> STM Message
newMessage msg id = do
      return Message
            { idMessage = id
              , message = msg
            }

-- Codigo Teste

-- printMessage :: Message -> IO ()
-- printMessage = do
--   messagemap <- readTVar messages
--   mapM_ (\message -> hPutStrLn clientHandle message) (Map.elems messagemap)

--broadcast

broadcast :: Server -> AllMessages -> Message -> STM ()
broadcast Server{..} AllMessages{..} message = do -- Função broadcast que recebe os dados do servidor e a mensagem e envia a mensagem para todos os clientes no servidor
  messagemap <- readTVar messages
  msg <- newMessage message "0"
  writeTVar messages $ Map.insert "0" msg messagemap
  clientmap <- readTVar clients -- readTVar : Recebe o Tvar clients definido previamente e retorna os valores armazenados no momento
  mapM_ (\client -> sendMessage client message) (Map.elems clientmap) -- Para cada client em clientmap aplica a função sendMessage, enviando a Mensagem
                                                                  -- mapM_ : Ignora os retornos das funções

-- sendMessage
sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg = -- Função sendMessage recebe um Client com todos os atributos e a mensagem a ser enviada
  writeTChan clientSendChan msg -- Escreve na FIFO o cliente que tá mandando e a mensagem
                                -- Tchan é um tipo abstrato que representa uma FIFO ilimitada

--Server handling

talk :: Handle -> Server -> AllMessages -> IO ()
talk handle server@Server{..} allMessages@AllMessages{..} = do -- função talk recebe o handle e o servidor com lista de clientes,
                                                               -- server@Server{..} nomeia todo o server com o apelido server
  hSetNewlineMode handle universalNewlineMode -- Configura modos de leitura (?) da linha como universal (usa o \n)

      -- Swallow carriage returns sent by telnet clients

  hSetBuffering handle LineBuffering -- Seta o buffer
  readName -- Chama função para ler o nome
 where

--readName

  readName = do -- Função readName lê o nome e autentica
    hPutStrLn handle "Please, send your username" -- Imprime mensagem usando o gerente IO
    name <- hGetLine handle -- Lê o nome com o hGetLine
    if null name -- Se estiver vazio
      then readName -- Pede pra ler de novo
      else mask $ \restore -> do        -- <1> Senão (?) mask: Executa uma computação de IO com excessões assíncronas mascaradas,
                                        -- tal que qualquer thread que tente lançar excessões na thread corrente
                                        -- será bloqueada até que as excessões assíncronas sejam desmascaradas.
                                        -- O argumento de mask é uma função lambda (\), que recebe como argumento outra função (restore).
                                        -- restore é usada para restaurar o estado de mascaramento prevalecente dentro do contexto da computação mascarada.
                                        -- A função lambda recebe restore e chama todo o bloco do abaixo:
             ok <- checkAddClient server allMessages name handle -- Chama a função checkAddClient para ver se já existe cliente com esse nome e guarda em ok
             case ok of -- se ok contiver Nothing, é porque o nome já existe
               Nothing -> restore $ do  -- <2> -- chama restore
                  hPrintf handle
                     "Name %s is in use please choose different username\n" name --Printa mensagem
                  readName -- Lê novamente o nome
               Just client -> -- Só para client
                  restore (runClient server client allMessages) -- <3> Se o nome for aceito, desmascaramos as exceções assíncronas ao chamar runClient
                                                    -- passando o servidor e o cliente
                      `finally` removeClient server allMessages name -- Por fim, remove o cliente através de removeClient passando o servidor e o nome

--checkAddClient
checkAddClient :: Server -> AllMessages -> ClientName -> Handle -> IO (Maybe Client)
checkAddClient server@Server{..} allMessages@AllMessages{..} name handle = atomically $ do -- checkAddClient recebe o servidor, nome do cliente e o handle
                                                               -- atomically: Torna possível rodar uma transação dentro de outra (executa uma série de ações STM atomicamente)
                                                               -- STM : Monad que suporta transações atômicas de memória
  clientmap <- readTVar clients -- readTVar : Recebe o Tvar clients definido previamente e retorna os valores armazenados no momento
  if Map.member name clientmap -- Map.member : recebe a chave(name) e o map(clientmap) e procura se a chave se encontra no map
    then return Nothing -- Se estiver retorna Nothing
    else do client <- newClient name handle -- Se não tiver cria novo cliente passando o nome e o handle e armazena em client
            writeTVar clients $ Map.insert name client clientmap -- writeTVar recebe um Tvar clients um Map
                                                                 -- Map.insert recebe o nome, o client e insere como chave e valor no map "clientmap", passando esse resultado para TVar
            broadcast server allMessages $ Notice (name ++ " joined") -- broadcast recebe servidor e a mensagem do tipo Notice que é composta por uma string (name ++ " joined"), compartilhando com todos
            return (Just client)                           -- Retorna o cliente adicionado

--removeClient
removeClient :: Server -> AllMessages -> ClientName -> IO ()
removeClient server@Server{..} allMessages@AllMessages{..} name = atomically $ do -- removeClient: Recebe como parametro o servidor e o nome do cliente
                                                      -- atomically: Permite transações dentro de outra transação
  modifyTVar' clients $ Map.delete name -- modifyTVar acessa TVar clients e o novo map, resultado do (Map.delete name), sem nome do cliente deletado
  broadcast server allMessages $ Notice (name ++ " left") -- Notifica por meio da função broadcast à todos os clientes do servidor que a pessoa saiu

--runClient
runClient :: Server -> Client -> AllMessages -> IO ()
runClient serv@Server{..} client@Client{..} allMessages@AllMessages{..} = do -- runClient recebe um servidor e um cliente
  race server receive -- race: executa duas ações de IO ao mesmo tempo e retorna a primeira a finalizar, a outra é cancelada
                      -- recebe server como primeira função e receive como segunda
  return ()           -- chama o retorno do race
 where
  receive = forever $ do -- Define a função receive como um loop
    msg <- hGetLine clientHandle -- hGetLine: Lê mensagem do gerenciador de IO do cliente (Handle) e retorna a mensagem (char) em msg
    atomically $ sendMessage client (Command msg) -- Dentro dessa transação executa sendMessage passando o client e uma mensagem do tipo Command

  server = join $ atomically $ do -- Define a função server
                                  -- join: Operador convencional de junção de monads (usado para remover um nível de estrutura monádica)
                                  --  join $ atomically $ : Composição dos monads join e atomically para rodar transações STM e ação IO retornada
   msg <- readTChan clientSendChan -- readTChan recebe a FIFO criada e passa seu conteúdo para msg
   return $ do --return da monad (?)
     continue <- handleMessage serv allMessages client msg -- Chama função handleMessage passando o servidor, o cliente e a mensagem, armazenando o retorno booleano em continue
     when continue $ server -- when : Faz parte da Control.Monad, é um condicional para execução de expressões candidatas
                            -- Se continue for verdadeiro, chama a função server recursivamente


--handleMessage different type of message
handleMessage :: Server -> AllMessages -> Client -> Message -> IO Bool
handleMessage server allMessages@AllMessages{..} client@Client{..} message = -- Define a handleMessage passando o servidor, o client e a mensagem
  case message of
     Notice msg         -> output $ "*** " ++ msg -- Se a mensagem for do tipo Notice a saída recebe *** no início
     Broadcast name id msg -> output $ name ++ ": [" ++ id ++ "] " ++ msg  -- Se for um broadcast passando o nome e a mensagem, a saída apresenta o formato nome e mensagem
     Reply name id msg -> output $ name ++ ": Reply for message " ++ id ++ " >> " ++ msg
     Command msg -> do -- Se for do tipo Command
       if head(words msg) == "KILL_SERVICE"
        then return False
        else if head(words msg) == "/r"
          then do
            atomically $ broadcast server allMessages $ Reply clientName (getId (words msg)) (getMessage (words msg))
            return True
          else do
            atomically $ broadcast server allMessages $ Broadcast clientName "1" msg  -- Senão roda as funções broadcast passando clientName e msg e server (?)
            return True
    where
      output s = do hPutStrLn clientHandle s; return True -- Define que o output acompanhado de qualquer argumento corresponde a
                                                          -- imprimir (hPutStrLn) usando o gerenciador de IO (clientHandle) a mensagem s


-- calcId :: Server -> String
--calcId allMessages@AllMessages{..} = do
--   messagemap <- readTVar messages
--   x <- count (Map.elems messagemap)
--   return True

getId :: [String] -> String
getId wd = do
  id <- head (tail wd)
  return id

getMessage :: [String] -> String
getMessage wd = do
  m <- unwords $ tail (tail wd)
  return m