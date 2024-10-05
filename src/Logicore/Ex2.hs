{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}

module Logicore.Ex2 where

import Control.Exception
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable
import Language.JavaScript.Inline

--js1 :: Int -> IO LBS.ByteString
js1 foo = do
  _session <- newSession defaultConfig
  eval @LBS.ByteString
    _session
    [js|
      console.log("aha");
      return `${$foo.a + 2}`;
    |]


m1 :: IO ()
m1 = do
  v <- js1 (EncodedJSON "{\"a\": 1}")
  print v
