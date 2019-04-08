{-# LANGUAGE RecordWildCards #-}
module Main where

import Text.Printf (printf, hPrintf)
import System.IO (Handle, BufferMode(LineBuffering), hSetNewlineMode, universalNewlineMode, hSetBuffering, hClose, hPutStrLn, hGetLine)
import qualified Data.Map as Map
import Network (PortID(PortNumber), listenOn, accept, withSocketsDo)
import System.Environment (getArgs)
import Control.Monad (join, forever, when)
import Control.Monad.STM (atomically)
import Control.Concurrent (forkFinally)
import Control.Concurrent.STM (STM)
import Control.Concurrent.STM.TVar (TVar, newTVar, newTVarIO, readTVar, readTVarIO, writeTVar, modifyTVar')
import Control.Concurrent.STM.TChan (TChan, newTChan, writeTChan, readTChan)
import Control.Concurrent.Async (race)
import Control.Exception (mask, finally)

-- main Function : Função principal do programa, faz todas as chamadas de métodos iniciais e mantém a conexão com o socket
main :: IO ()
main = withSocketsDo $ do -- Inicializar subsistema de rede em SO windows

  server <- newServer -- Chama função newServer, devolvendo um Servidor criado
  args <- getArgs -- Pega os argumentos passados como argumento na execução do programa
  allMessages <- newAllMessages -- Inicializa Tvar de mensagens


  let port = fromIntegral (read $ head args :: Int) -- read: Pega bloco de coisa e transforma em valor
                                                    -- | head args:Pega primeiro argumento de args | :: Int - Converte para inteiro
                                                    -- | fromIntegral : transforma inteiro ou integer em tipo de número mais genérico (Ex: Somar float e int)

  sock <- listenOn (PortNumber port) -- Salva em sock o retorno de listenOn, passando número da porta (O retorno é um socket (IO Socket - listening socket))
                                     -- PortNumber : Tipo relativo a um num

  printf "===================================================\n"
  printf "          Welcome to the Haskell Chat!!!\n"
  printf "===================================================\n"

  printf "-----------------------------------------------------------\n"
  printf "    Chat server running on port %s on all connected IPs\n" (show port) -- Imprime a porta que será utilizada
  printf "-----------------------------------------------------------\n"


  forever $ do -- forever: Define um loop
    (handle, host, port) <- accept sock -- Aceita uma conexão ao socket
                                        -- Retorna o gerenciador de IO, número do host e a porta da conexão
    printf "Connection %s: %s\n" host (show port) -- Imprime host e porta - Converte port para string para imprimir
    forkFinally (talk handle server allMessages) (\_ -> hClose handle)  -- Dá fork na thread e chama a função fornecida quando a thread está perto de finalizar
                                                              -- Ao finalizar uma "talk" (talk handle server), chama  (\_ -> hClose handle)
                                                              --  (\_ -> hClose handle) : Finaliza handle, se hdl for gravável, buffer é liberado para hflush

-- Data structures and initialisation

--Client

--Define que o ClientName é string
type ClientName = String

-- Client data : Define estrutura do cliente, composto por nome, handle e fila de mensagens
data Client = Client
  { clientName     :: ClientName -- Nome do cliente
  , clientHandle   :: Handle -- Gerenciamento de entradas e saídas
  , clientSendChan :: TChan Message -- Fila de mensagens
  }

--newClient Function : Inicializa cliente com a FIFO que necessária para armazenar as mensagens
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

-- Server data : Define a estrutura do servidor como uma Tvar que armazena um Map cuja chave é o nome do Cliente e Client
data Server = Server
  { clients :: TVar (Map.Map ClientName Client) -- Server é composto por clients cuja estrutura consiste em local de memória compatilhada que
                                            -- contém o mapeamento dos nomes de todos os clientes?
  }

--newServer Function : Inicializa o servidor com sua TVar de clientes vazia
                    -- Entrada : Não possui
                    -- Saída : Servidor inicializado

newServer :: IO Server
newServer = do -- Função new server cria servidor e retorna-o
  c <- newTVarIO Map.empty -- Cria newTVarIO versão IO de TVar, vazio
  return Server { clients = c } -- Retorna servidor preenchido com TVar de clientes "vazio"

--Message

-- Message data = Define as estruturas que uma Message pode adquirir
data Message = Notice String -- Mensagem do servidor
             | Broadcast ClientName String String -- Mensagem de texto para vários clientes
             | Command String -- Linha de texto recebido do usuário
             | Reply ClientName String String -- Mensagem de resposta a uma específica, recebe o nome do cliente, id da msg respondida e a msg de resposta
             | Message
             {
               idMessage :: String
               ,message :: Message
             }

--- AllMessages data : Define AllMessages como TVar de map de mensagens e contador de mensagens
data AllMessages = AllMessages
  { messages :: TVar (Map.Map String Message)
  , countMessages :: TVar (Int)
  }

--newAllMessage Function : Inicializa AllMessages criando TVars dos atributos
                        -- Entrada : Nenhuma
                        -- Saída : AllMessages inicializada, onde messages possui TVarIO vazia e countMessages TVarIO zerada

newAllMessages :: IO AllMessages
newAllMessages = do
  m <- newTVarIO Map.empty
  c <- newTVarIO 0
  return AllMessages {
      messages = m
    , countMessages = c
    }

-- newMessage Function : Cria uma nova mensagem do "tipo" Message
                      -- Entrada: Mensagem, Id
                      -- Saída : Mensagem

newMessage :: Message -> String -> STM Message
newMessage msg id = do
      return Message
            { idMessage = id
              , message = msg
            }

--broadcast Function : Envia as mensagens digitadas para todas os clientes conectados
                      -- Entradas: Servidor, Todas as mensagens, Mensagem a ser enviada
                      -- Saída: Mensagens de todos os clientes são colocadas na FIFO

broadcast :: Server -> AllMessages -> Message -> STM ()
broadcast Server{..} AllMessages{..} message = do -- Função broadcast que recebe os dados do servidor e a mensagem e envia a mensagem para todos os clientes no servidor
  case message of
    Broadcast name id msg -> do -- Case para identificar tipo de mensagem que necessita da geração de id
      i <- readTVar countMessages -- Lê TVar que armazena os ids já gerados
      writeTVar countMessages $ i + 1 -- Escreve um novo id na TVar , sendo o anterior + 1
      messagemap <- readTVar messages -- Lê TVar das mensagens
      msg <- newMessage message (show $ i + 1) -- Cria uma nova mensagem com o id calculado
      writeTVar messages $ Map.insert (show $ i + 1) msg messagemap -- Escreve na TVar de Mensagens o Map de mensagens com o id calculado
      defaultBroadcast
    _ -> defaultBroadcast
  where
    defaultBroadcast = do
    clientmap <- readTVar clients -- readTVar : Recebe o Tvar clients definido previamente e retorna os valores armazenados no momento
    mapM_ (\client -> sendMessage client message) (Map.elems clientmap) -- Para cada client em clientmap aplica a função sendMessage, enviando a Mensagem
                                                                  -- mapM_ : Ignora os retornos das funções

-- sendMessage Function : Função que escreve a mensagem enviada na FIFO (Lida ao rodar o runClient)
                        -- Entrada : Cliente e Mensagem
                        -- Saída : Mensagem na fila

sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg = -- Função sendMessage recebe um Client com todos os atributos e a mensagem a ser enviada
  writeTChan clientSendChan msg -- Escreve na FIFO o cliente que tá mandando e a mensagem
                                -- Tchan é um tipo abstrato que representa uma FIFO ilimitada

--Server handling

-- talk Function : Função que configura os modos de leitura e lê o nome do cliente
                  -- Entradas : Handle, Servidor, Todas as mensagens
                  -- Saída : Nome do cliente

talk :: Handle -> Server -> AllMessages -> IO ()
talk handle server@Server{..} allMessages@AllMessages{..} = do -- função talk recebe o handle e o servidor com lista de clientes e todas as mensagens
                                                               -- server@Server{..} nomeia todo o server com o apelido server
  hSetNewlineMode handle universalNewlineMode -- Configura modos de leitura (?) da linha como universal (usa o \n)

      -- Swallow carriage returns sent by telnet clients

  hSetBuffering handle LineBuffering -- Seta o buffer
  readName -- Chama função para ler o nome
 where



--readName Function : Lê um nome válido (Não vazio, não existente em Map)
                    -- Entradas : Não explícita
                    -- Saída : Execução do runClient, possibilita início da conversação

  readName = do
    hPutStrLn handle "\ESC[2J"
    hPutStrLn handle "\n------------------------------------------"
    hPutStrLn handle "Please, Enter a username:" -- Imprime mensagem usando o gerente IO
    name <- hGetLine handle -- Lê o nome com o hGetLine
    hPutStrLn handle "\n------------------------------------------"
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
                     "Username '%s' is in use, please choose different one\n" name --Printa mensagem
                  readName -- Lê novamente o nome
               Just client -> -- Se for um Client (não existe ainda)
                  restore (runClient server client allMessages handle) -- <3> Se o nome for aceito, desmascaramos as exceções assíncronas ao chamar runClient
                                                    -- passando o servidor e o cliente
                      `finally` removeClient server allMessages name -- Por fim, remove o cliente através de removeClient passando o servidor e o nome


--checkAddClient Function : Verifica se já existe cliente com o nome fornecido
                          -- Entrada : Servidor, Todas as  mensagens, Nome do Cliente, handle
                          -- Saída : Client, se o nome não for chave no Map, Nothing, se for



checkAddClient :: Server -> AllMessages -> ClientName -> Handle -> IO (Maybe Client)
checkAddClient server@Server{..} allMessages@AllMessages{..} name handle = atomically $ do -- checkAddClient recebe o servidor, as mensagens, o nome do cliente e o handle
                                                               -- atomically: Torna possível rodar uma transação dentro de outra (executa uma série de ações STM atomicamente)
                                                               -- STM : Monad que suporta transações atômicas de memória
  clientmap <- readTVar clients -- readTVar : Recebe o Tvar clients definido previamente e retorna os valores armazenados no momento
  if Map.member name clientmap -- Map.member : recebe a chave(name) e o map(clientmap) e procura se a chave se encontra no map
    then return Nothing -- Se estiver retorna Nothing
    else do client <- newClient name handle -- Se não tiver cria novo cliente passando o nome e o handle e armazena em client
            writeTVar clients $ Map.insert name client clientmap -- writeTVar recebe um Tvar clients um Map
                                                                 -- Map.insert recebe o nome, o client e insere como chave e valor no map "clientmap", passando esse resultado para TVar
            broadcast server allMessages $ Notice ( name ++ " joined\n------------------------------------------\n") -- broadcast recebe servidor e a mensagem do tipo Notice que é composta por uma string (name ++ " joined"), compartilhando com todos
            return (Just client)                           -- Retorna o cliente adicionado

--removeClient Function : Remove cliente do map
                        -- Entradas: Servidor, Todas as mensagens, Nome do cliente
                        -- Saídas: Mensagem de saída de um membro


removeClient :: Server -> AllMessages -> ClientName -> IO ()
removeClient server@Server{..} allMessages@AllMessages{..} name = atomically $ do -- removeClient: Recebe como parametro o servidor e o nome do cliente
                                                      -- atomically: Permite transações dentro de outra transação
  modifyTVar' clients $ Map.delete name -- modifyTVar acessa TVar clients e o novo map, resultado do (Map.delete name), sem nome do cliente deletado
  broadcast server allMessages $ Notice (name ++ " left") -- Notifica por meio da função broadcast à todos os clientes do servidor que a pessoa saiu

--runClient Function: Garante a concorrência entre o servidor de mensagens e o receptor
                    -- Entradas: Servidor, Cliente, Todas as mensagens
                    -- Saída: return ()


runClient ::  Server -> Client -> AllMessages -> Handle-> IO ()
runClient serv@Server{..} client@Client{..} allMessages@AllMessages{..} handle= do -- runClient recebe um servidor e um cliente
  race server receive -- race: executa duas ações de IO ao mesmo tempo e retorna a primeira a finalizar, a outra é cancelada
                      -- recebe server como primeira função e receive como segunda
  printSession
  return ()           -- chama o retorno do race
 where

  printSession = do
    hPutStrLn handle "----------------------------------------"
    hPutStrLn handle "Exiting the chat... Come back later!"
    hPutStrLn handle "----------------------------------------"

-- receive Function : Mantem o "receptor" de mensagens rodando, lê do handle do cliente e envia (salva na FIFO)
                    -- Entrada : Sem argumento explícito
                    -- Saída : Não identificada

  receive = forever $ do  -- Define um loop
    msg <- hGetLine clientHandle -- hGetLine: Lê mensagem do gerenciador de IO do cliente (Handle) e retorna a mensagem (char) em msg
    atomically $ sendMessage client (Command msg) -- Dentro dessa transação executa sendMessage passando o client e uma mensagem do tipo Command
    hPrintf handle ">>>"

  -- server Function : Lê as mensagens da FIFO e envia ao handle para que seja realizado o broadcast
                      -- Entradas : Nenhuma entradas
                      -- Saída: status do servidor (?)

  server = join $ atomically $ do -- join: Operador convencional de junção de monads (usado para remover um nível de estrutura monádica)
                                  --  join $ atomically $ : Composição dos monads join e atomically para rodar transações STM e ação IO retornada
   msg <- readTChan clientSendChan -- readTChan recebe a FIFO criada e passa seu conteúdo para msg
   return $ do --return da monad (?)
     continue <- handleMessage serv allMessages client msg -- Chama função handleMessage passando o servidor, o cliente e a mensagem, armazenando o retorno booleano em continue
     when continue $ server -- when : Faz parte da Control.Monad, é um condicional para execução de expressões candidatas
                            -- Se continue for verdadeiro, chama a função server recursivamente


--handleMessage different type of message

-- handleMessage Function : Trata a saída para os diferentes tipos de mensagem, chamndo broadcast para enviá-las
                  -- Entradas: Servidor, Todas as mensagens, O Cliente e a mensagem
                  -- Saída: Booleano que indica se é pra continuar rodando o servidor (False - Não , True - Sim)

handleMessage :: Server -> AllMessages -> Client -> Message -> IO Bool
handleMessage server allMessages@AllMessages{..} client@Client{..} message = -- Define a handleMessage passando o servidor, o client e a mensagem
  case message of
     Notice msg            -> output $ "\n------------------------------------------\n*** " ++ msg -- Se a mensagem for do tipo Notice a saída recebe *** no início
     Broadcast name id msg -> output $ name ++ ": [" ++ id ++ "] " ++ msg  ++ "\n" -- Se for um broadcast passando o nome e a mensagem, a saída apresenta o formato nome e mensagem
     Reply name id msg     -> output $ name ++ ": Reply for message " ++ id ++ " >> " ++ msg ++ "\n"
     Command msg -> do -- Se for do tipo Command
       if head(words msg) == "/q"
        then return False
        else if head(words msg) == "/r"
          then do
            checked <- checkId allMessages (getId (words msg))
            if checked == True -- Se id for válido
              then do
                atomically $ broadcast server allMessages $ Reply clientName (getId (words msg)) (getMessage (words msg)) -- Faz broadcast
              else do
                atomically $ sendMessage client (Notice "Can't reply. Invalid message identifier!") -- Informa que mensagem que está rentando replicar não existe
            return True
          else do -- Se não for de reply realiza Broadcast da mensagem normalmente
            i <- readTVarIO countMessages
            atomically $ broadcast server allMessages $ Broadcast clientName (show $ i + 1) msg  -- Senão roda as funções broadcast passando clientName e msg e server (?)
            return True
    where
      output s = do
          hPutStrLn clientHandle s -- Define que o output acompanhado de qualquer argumento corresponde a
          return True -- imprimir (hPutStrLn) usando o gerenciador de IO (clientHandle) a mensagem s

-- checkId Function : Checa a validade do ID informado (Entre 1 e o último criado)
                    -- Entradas : Todas as mensagens e o id informado pelo usuário
                    -- Saída: booleano que indica validade ou não do id

checkId :: AllMessages -> String -> IO Bool
checkId AllMessages{..} idEntered = do
  let idInt = read idEntered :: Int
  count <- readTVarIO countMessages
  if idInt < 1 || idInt > count
    then
      return False -- Se inválido retorna false
    else
      return True -- Se válido retorna True

getId :: [String] -> String
getId wd = do
  id <- head (tail wd)
  return id

-- getMessage Function : Recupera só a parte relativa à mensagem do que o cliente digitar no console
                       -- Entradas : O que foi digitado no console
                       -- Saída : Somente a parte relativa à mensagem

getMessage :: [String] -> String
getMessage wd = do
  m <- unwords $ tail (tail wd)
  return m
