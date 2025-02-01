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
import Language.JavaScript.Inline.Core

--js1 :: Int -> IO LBS.ByteString
js1 _session foo = do
  eval @EncodedJSON
    _session
    [js|
      console.log("aha");
      $foo.a += 1;
      $foo.b = `${$foo.a + 2}`;
      $foo.c = new Date();
      return $foo;
    |]


j1 :: IO ()
j1 = do
  _session <- newSession defaultConfig
  v <- js1 _session (EncodedJSON "{\"a\": 1}")
  print $ unEncodedJSON v
  --v <- js1 _session (EncodedJSON "{\"a\": 2}")
  --print v
  --v <- js1 _session (EncodedJSON "{\"a\": 3}")
  --print v
