module Bitcoin.Types where

import           Data.ByteString hiding (putStrLn)

type Signature = ByteString

newtype Error = Error String

type ChainM a = Either Error a

