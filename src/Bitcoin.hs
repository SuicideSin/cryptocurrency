module Bitcoin where

import           Bitcoin.Network
import           Bitcoin.Log
import           Bitcoin.Crypto
import           Bitcoin.Tx
import           Bitcoin.Types

import           Crypto.Blockchain

import           Crypto.Hash (Digest, SHA256(..), HashAlgorithm, hashlazy, digestFromByteString, hashDigestSize)
import           Crypto.Hash.Tree (HashTree)
import qualified Crypto.Hash.Tree as HashTree
import           Crypto.Error (CryptoFailable(CryptoPassed))
import           Crypto.Number.Serialize (os2ip)

import           Control.Concurrent.STM.TChan
import           Control.Concurrent.Async (async, race)
import           Control.Concurrent (MVar, readMVar, modifyMVar_, newMVar, threadDelay)
import           Control.Monad (forever)
import           Control.Monad.Reader
import           Control.Monad.Logger

import           Data.Binary (Binary, get, put, encode)
import           Data.ByteString hiding (putStrLn)
import           Data.ByteString.Lazy (toStrict)
import           Data.ByteString.Base58
import           Data.ByteArray (convert, ByteArray, zero)
import qualified Data.ByteArray as ByteArray
import           Data.Foldable (toList)
import qualified Data.List.NonEmpty as NonEmpty
import           Data.Maybe (fromJust)
import qualified Data.Sequence as Seq
import           Data.Sequence   (Seq, (|>))
import           Data.IORef
import           Data.Word (Word64, Word32)
import           Data.Int (Int32)

import qualified Network.Socket as NS
import           GHC.Generics (Generic)
import           GHC.Stack (HasCallStack)
import           Debug.Trace

newtype Valid a = Valid a

type Bitcoin = Blockchain Tx'
data Message a =
      MsgTx Tx'
    | MsgBlock (Block a)
    | MsgPing
    deriving (Show, Generic)

instance Binary a => Binary (Message a)
deriving instance Eq a => Eq (Message a)

class Validate a where
    validate :: a -> ChainM a

instance Validate (Block a) where
    validate = validateBlock

instance Validate (Blockchain a) where
    validate = validateBlockchain

validateBlockchain :: Blockchain a -> Either Error (Blockchain a)
validateBlockchain bc = Right bc

validateBlock :: Block a -> Either Error (Block a)
validateBlock blk = Right blk

isGenesisBlock :: Block' a -> Bool
isGenesisBlock blk =
    (blockPreviousHash . blockHeader) blk == zeroHash

maxHash :: HashAlgorithm a => Digest a
maxHash = fromJust $
    digestFromByteString (ByteArray.replicate (hashDigestSize SHA256) maxBound :: ByteString)

newtype Mempool tx = Mempool { fromMempool :: Seq tx }
    deriving (Show, Monoid)

addTx :: tx -> Mempool tx -> Mempool tx
addTx tx (Mempool txs) = Mempool (txs |> tx)

readTransactions :: MonadReader Env m => m (Seq Tx')
readTransactions = undefined

findBlock :: (Monad m, Traversable t) => t tx -> m (Block tx)
findBlock = undefined

listenForBlock :: MonadIO m => m (Block tx)
listenForBlock = undefined

proposeBlock :: MonadIO m => Block tx -> m ()
proposeBlock = undefined

updateMempool :: (MonadReader Env m, Traversable t) => t tx -> m ()
updateMempool = undefined

mineBlocks :: (MonadReader Env m, MonadLogger m, MonadIO m) => m ()
mineBlocks = forever $ do
    txs <- readTransactions
    result <- io $ race (findBlock txs) (listenForBlock)
    case result of
        Left foundBlock ->
            proposeBlock foundBlock
        Right receivedBlock ->
            updateMempool (blockData receivedBlock)

data Env = Env
    { envBlockchain :: MVar (Blockchain Tx')
    , envMempool    :: MVar (Mempool Tx')
    , envLogger     :: Logger
    }

newEnv :: IO Env
newEnv = do
    bc <- newMVar mempty
    mp <- newMVar mempty
    pure $ Env
        { envBlockchain = bc
        , envMempool    = mp
        , envLogger     = undefined
        }

io :: MonadIO m => IO a -> m a
io = liftIO

startNode
    :: (MonadReader Env m, MonadLogger m, MonadIO m)
    => NS.ServiceName
    -> [(NS.HostName, NS.ServiceName)]
    -> m ()
startNode port peers = do
    net :: Internet (Message Tx') <- listen port
    io . async $ connectToPeers net peers
    io . async $ forever $ do
        broadcast net MsgPing
        threadDelay $ 1000 * 1000

    forever $ do
        msg <- receive net
        case msg of
            MsgTx tx -> do
                logInfoN "Tx"
                mp <- asks envMempool
                io $ modifyMVar_ mp (pure . addTx tx)
            MsgBlock blk ->
                logInfoN "Block"
            MsgPing ->
                logInfoN "Ping"

broadcastTransaction :: Socket n (Message a) => n -> Tx (Digest SHA256) -> IO ()
broadcastTransaction net tx = do
    broadcast net (MsgTx tx)

block :: [a] -> ChainM (Block' a)
block xs = validate $
    Block
        BlockHeader
            { blockPreviousHash = zeroHash
            , blockDifficulty   = undefined
            , blockTimestamp    = undefined
            , blockRootHash     = undefined
            , blockNonce        = undefined
            }
        (Seq.fromList xs)

genesisDifficulty :: Difficulty
genesisDifficulty = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

genesisBlock :: [a] -> ChainM (Block' a)
genesisBlock xs = validate $
    Block
        BlockHeader
            { blockPreviousHash = zeroHash
            , blockDifficulty   = undefined
            , blockTimestamp    = undefined
            , blockRootHash     = undefined
            , blockNonce        = undefined
            }
        (Seq.fromList xs)

blockchain :: [Block' a] -> ChainM (Blockchain a)
blockchain blks = validate $ Seq.fromList blks

hashValidation :: Integer -> BlockHeader -> Bool
hashValidation target bh =
    digest > zeroHash
  where
    digest = hashlazy $ encode bh :: Digest SHA256

proofOfWork :: (BlockHeader -> Bool) -> BlockHeader -> BlockHeader
proofOfWork validate bh | validate bh =
    bh
proofOfWork validate bh@BlockHeader { blockNonce } =
    proofOfWork validate bh { blockNonce = blockNonce + 1 }

appendBlock :: Binary a => Seq a -> Blockchain a -> ChainM (Blockchain a)
appendBlock dat bc =
    validate $ bc |> new
  where
    prev = Seq.index bc (Seq.length bc - 1)
    new = Block header dat
    header = BlockHeader
        { blockPreviousHash = blockHash prev
        , blockRootHash     = rootHash
        , blockDifficulty   = undefined
        , blockTimestamp    = undefined
        , blockNonce        = undefined
        }
    rootHash =
        HashTree.rootHash . HashTree.fromList . NonEmpty.fromList . toList $
            fmap (hashlazy . encode) dat

blockHash :: (Binary a) => Block a -> Digest SHA256
blockHash blk =
    hashlazy $ encode blk

connectToPeers :: Internet a -> [(NS.HostName, NS.ServiceName)] -> IO ()
connectToPeers net peers =
    mapM_ (connect net) peers

