{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Network.Wai.Handler.Warp (run)
import Web.Twain
import Data.Aeson
import qualified Data.Aeson.KeyMap          as KM
import qualified Data.Aeson.Key             as K
import qualified Data.Vector as V
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as T
import qualified Data.Text.IO               as T
import qualified Data.Text.Lazy             as TL
import qualified Data.Text.Lazy.Encoding    as TL
import qualified Data.Text.Lazy.IO          as TL

import Logicore.Matcher.Core
import Logicore.Matcher.Additional
import Logicore.Matcher.Python

main :: IO ()
main = do
  run 3002 $
    foldr ($)
      (notFound missing)
      [ get "/" index
      , post "echo:name" echo
      , post "python-matcher-1" pythonMatcher1
      , post "json-matcher-1" jsonMatcher1
      ]

index :: ResponderM a
index = send $ html "Hello World!"

echo :: ResponderM a
echo = do
  name <- param "name"
  send $ html $ "Hello, " <> name

jsonMatcher1 :: ResponderM a
jsonMatcher1 = do
  b <- (fromBody :: ResponderM Value)
  let a = do
          e <- (m2e "JSON root element must be a map") $ asKeyMap b
          code <- (m2e "JSON root element must have code") $ KM.lookup (K.fromString "data") e
          grammar <- (m2e "JSON root element must have grammar") $ KM.lookup (K.fromString "grammar") e
          mp <- (m2e "Cannot decode MatchPattern from presented grammar") $ (
            ((decode . encode) grammar) :: Maybe MatchPattern) -- TODO
          r <- case matchAndCollapse mp return code of
                  MatchFailure s -> Left ("MatchFailure: " ++ s)
                  NoMatch x -> Left ("NoMatch: " ++ x)
                  MatchSuccess (f, r) -> Right $ (KM.fromList [
                    (K.fromString "funnel", (Array . V.fromList) f),
                    (K.fromString "result", r)])
          return (Object r)
  send $ Web.Twain.json $ case a of
       Left e -> Object (KM.fromList [(K.fromString "error", (String . T.pack) ("Error: " ++ e))])
       Right x -> x

pythonMatcher1 :: ResponderM a
pythonMatcher1 = do
  b <- (fromBody :: ResponderM Value)
  let a = do
          e <- (m2e "JSON root element must be a map") $ asKeyMap b
          code <- (m2e "JSON root element must have code") $ KM.lookup (K.fromString "data") e
          grammar <- (m2e "JSON root element must have grammar") $ KM.lookup (K.fromString "grammar") e
          mp <- pythonMatchPattern grammar
          let c = do
                  -- _ <- error $ show $ mp
                  r <- case matchAndCollapse mp return code of
                          MatchFailure s -> Left ("MatchFailure: " ++ s)
                          NoMatch x -> Left ("NoMatch: " ++ x)
                          MatchSuccess (f, r) -> Right $ (KM.fromList [
                            -- (K.fromString "tree", toJSON $ MatchObjectPartialResult (Object (KM.fromList [])) (KM.fromList [])),
                            (K.fromString "grammar", toJSON $ mp),
                            (K.fromString "funnel", (Array . V.fromList) f),
                            (K.fromString "t1", String $ T.pack $ show mp),
                            (K.fromString "t2", String $ T.pack $ show code),
                            (K.fromString "result", r {-(String . T.pack) $ (show r) ++ "\n\n" ++ (show mp)-})])
                  return (Object r)
          case c of
              Left e -> Right $ Object (KM.fromList [
                (K.fromString "error", (String . T.pack) ("Error: " ++ e)),
                (K.fromString "result", Null),
                (K.fromString "grammar", toJSON $ mp),
                (K.fromString "funnel", Null),
                (K.fromString "t1", String $ T.pack $ show mp),
                (K.fromString "t2", String $ T.pack $ show code)
                ])
              Right r -> Right r
  let f = case a of
               Left _ -> status (Status {statusCode = 400, statusMessage = "request error"})
               Right _ -> id
  send $ f $ Web.Twain.json $ case a of
       Left e -> Object (KM.fromList [(K.fromString "error", (String . T.pack) ("Error: " ++ e))])
       Right x -> x

missing :: ResponderM a
missing = send $ html "Not found..."
