{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE OverloadedStrings #-}


module Logicore.Matcher.Core where
{-  (
  --  matchPattern
  --, matchPattern
  --, contextFreeMatch
  --, ContextFreeGrammar(..)
  --, MatchPattern(..)
  --, MatchStatus(..)
  -- result processing fns
  --, gatherFunnel
  -- Matcher utils
   m2ms
  -- Aeson utils
  , asKeyMap
  , asArray
  , asString
  , catMaybes
  -- common utils
  , m2e
  , safeHead
  ) where-}

import qualified Data.Vector.Generic
--import qualified Data.Set
import qualified Data.List        as L
import GHC.Generics
import Data.Aeson
--import Data.ByteString            as B
--import Data.ByteString.Lazy       as BL
import Data.Text                  as T
--import Data.Text.Encoding         as T
--import Data.Text.IO               as T
import Data.Text.Lazy             as TL
import Data.Text.Lazy.Encoding    as TL
--import Data.Text.Lazy.IO          as TL
--import Data.Map                   as M
import Data.Aeson.KeyMap          as KM
import Data.Aeson.Key             as K
import qualified Data.Scientific as Sci
import qualified Data.Vector as V
import Prelude                    as P
import Control.Monad()
--import qualified Data.ByteString.UTF8       as BLU
--import Logicore.Matcher.Utils

data MatchStatus a = MatchSuccess a
                 | MatchFailure String
                 | NoMatch String
                 deriving (Eq, Show)

instance Functor MatchStatus where
  fmap f (MatchSuccess m) = MatchSuccess (f m)
  fmap _ (MatchFailure x) = MatchFailure x
  fmap _ (NoMatch x) = NoMatch x

instance Applicative MatchStatus where
  (<*>) (MatchSuccess f) (MatchSuccess m) = MatchSuccess (f m)
  (<*>) _ (MatchFailure x) = (MatchFailure x)
  (<*>) (MatchFailure x) _ = (MatchFailure x)
  (<*>) (NoMatch x) _ = (NoMatch x)
  (<*>) _ (NoMatch x) = (NoMatch x)
  pure x = MatchSuccess x

instance Monad MatchStatus where
  (>>=) (MatchSuccess m) f = f m
  (>>=) (MatchFailure m) _ = (MatchFailure m)
  (>>=) (NoMatch m) _ = (NoMatch m)

-- CF matcher

data ContextFreeGrammar a = SeqNode [(ContextFreeGrammar a)]
                          | StarNode [(ContextFreeGrammar a)]
                          | PlusNode [(ContextFreeGrammar a)]
                          | OrNode String (ContextFreeGrammar a)
                          | OptionalNodeValue (ContextFreeGrammar a)
                          | OptionalNodeEmpty
                          | CharNode a -- i.e. result node
                          | Char a
                          | Seq [(ContextFreeGrammar a)]
                          | Or [(String, (ContextFreeGrammar a))]
                          | Star (ContextFreeGrammar a)
                          | Plus (ContextFreeGrammar a)
                          | Optional (ContextFreeGrammar a)
                            deriving (Generic, Eq, Show, Foldable)

instance ToJSON a => ToJSON (ContextFreeGrammar a) where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON a => FromJSON (ContextFreeGrammar a)

contextFreeMatch' :: (Eq a, Show a, Show b) => ContextFreeGrammar a -> [b] -> (a -> b -> MatchStatus a) -> MatchStatus ([b], ContextFreeGrammar a)
contextFreeMatch' (Char _) [] _ = NoMatch "can't read char"
contextFreeMatch' (Char a) (x:xs) matchFn =
  case matchFn a x of
       NoMatch s -> NoMatch ("no char match: " ++ s)
       MatchFailure s -> MatchFailure s
       MatchSuccess a' -> MatchSuccess (xs, CharNode a')

contextFreeMatch' (Seq as) xs matchFn = (fmap . fmap) SeqNode $ L.foldl' f (MatchSuccess (xs, mempty)) as
  where f acc' a = do
          (xs, result) <- acc'
          (xs', result') <- contextFreeMatch' a xs matchFn
          return (xs', result ++ [result'])

contextFreeMatch' (Or as) xs matchFn = L.foldr f (NoMatch "or mismatch") as
  where f (opt, a) b = do
          case contextFreeMatch' a xs matchFn of
               NoMatch _ -> b
               MatchFailure s -> MatchFailure s
               MatchSuccess (xs', r) -> MatchSuccess (xs', OrNode opt r)

contextFreeMatch' (Star a) xs matchFn = (fmap . fmap) StarNode $ f (MatchSuccess (xs, mempty))
  where --f :: MatchStatus ([b], ContextFreeGrammar a) -> MatchStatus ([b], ContextFreeGrammar a)
        f acc = do
          (xs, result) <- acc
          case contextFreeMatch' a xs matchFn of
               NoMatch _ -> acc
               MatchFailure s -> MatchFailure s
               MatchSuccess (xs', result') -> f (MatchSuccess (xs', result ++ [result']))

contextFreeMatch' (Plus a) xs matchFn = do
  (xs', subresult) <- contextFreeMatch' (Seq [a, Star a]) xs matchFn
  rs' <- case subresult of
              (SeqNode [r, (StarNode rs)]) -> MatchSuccess (r:rs)
              _ -> NoMatch "impossible"
  return (xs', (PlusNode rs'))
  

contextFreeMatch' (Optional a) xs matchFn =
  case contextFreeMatch' a xs matchFn of
       NoMatch _ -> MatchSuccess (xs, OptionalNodeEmpty)
       MatchFailure s -> MatchFailure s
       MatchSuccess (xs', subresult) -> MatchSuccess (xs', OptionalNodeValue subresult)

contextFreeMatch' a xs _ = error ("no match for: " ++ (show a) ++ " " ++ (show xs))

contextFreeMatch :: (Eq a, Show a, Show b) =>
                    ContextFreeGrammar a
                    -> [b]
                    -> (a -> b -> MatchStatus a)
                    -> MatchStatus (ContextFreeGrammar a)

contextFreeMatch a xs matchFn = do
  (rest, result) <- contextFreeMatch' a xs matchFn
  case P.length rest == 0 of
       False -> NoMatch ("rest left: " ++ show rest)
       True -> MatchSuccess result

-- helpers

m2e :: e -> Maybe a -> Either e a
m2e e m = case m of
               Nothing -> Left e
               Just x -> Right x

safeHead :: [a] -> Maybe a
safeHead (x:_) = Just x
safeHead _ = Nothing

catMaybes xs = L.foldl' f mempty xs
  where f a b = case b of
                     Nothing -> a
                     Just x -> a ++ [x]

asKeyMap :: Value -> Maybe Object
asKeyMap (Object a) = Just a
asKeyMap _ = Nothing

asArray :: Value -> Maybe [Value]
asArray (Array a) = Just $ Data.Vector.Generic.toList a
asArray _ = Nothing

asString (String x) = Just x
asString _ = Nothing

--- Match functions begin

-- | A JSON \"array\" (sequence).
--type MatchArray = V.Vector MatchPattern -- TODO just use list?

{-data MatchOp = MatchOp (MatchPattern -> MatchStatus MatchPattern)
instance Show MatchOp where
  show _ = "MatchOp"

instance Eq MatchOp where
  (==) _ _ = False

instance Generic MatchOp where
  --

instance ToJSON MatchOp where
  --

instance FromJSON MatchOp
    -- No need to provide a parseJSON implementation.-}

-- Match<What>[<How>], Match<What>[<How>]Result

data ObjectKeyMatch a = KeyReq a | KeyOpt a | KeyExt Value deriving (Generic, Eq, Show)

instance ToJSON a => ToJSON (ObjectKeyMatch a) where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON a => FromJSON (ObjectKeyMatch a)
    -- No need to provide a parseJSON implementation.

data ArrayValMatch a = MatchedVal a | ExtraVal Value deriving (Generic, Eq, Show)

instance ToJSON a => ToJSON (ArrayValMatch a) where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON a => FromJSON (ArrayValMatch a)
    -- No need to provide a parseJSON implementation.

                    -- structures - object
data MatchPattern = MatchObjectFull (KeyMap (ObjectKeyMatch MatchPattern))
                  | MatchObjectPartial (KeyMap (ObjectKeyMatch MatchPattern))
                  -- structures - array
                  | MatchArrayAll MatchPattern
                  | MatchArraySome MatchPattern
                  | MatchArrayOne MatchPattern
                  | MatchArrayExact [MatchPattern]
                  | MatchArrayContextFree (ContextFreeGrammar MatchPattern)
                  -- literals: match particular value of
                  | MatchStringExact !T.Text
                  | MatchNumberExact !Sci.Scientific
                  | MatchBoolExact !Bool
                  -- literals: match any of
                  | MatchString
                  | MatchNumber
                  | MatchBool
                  -- literals: null is just null
                  | MatchNull
                  -- conditions
                  | MatchAny
                  | MatchOr (KeyMap MatchPattern)
                  | MatchIfThen MatchPattern MatchPattern String
                  -- funnel
                  | MatchFunnel
                  | MatchFunnelKeys
                  | MatchFunnelKeysU
                  -- special
                  | MatchRef String
                    deriving (Generic, Eq, Show)

instance ToJSON MatchPattern where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON MatchPattern
    -- No need to provide a parseJSON implementation.

                    -- structures - object
data MatchResult = MatchObjectFullResult (KeyMap (ObjectKeyMatch MatchResult))
                 | MatchObjectPartialResult (KeyMap (ObjectKeyMatch MatchResult))
                 -- structures - array
                 | MatchArrayAllResult (V.Vector MatchResult)
                 | MatchArraySomeResult (V.Vector (ArrayValMatch MatchResult))
                 | MatchArrayOneResult MatchResult
                 | MatchArrayExactResult [MatchResult]
                 | MatchArrayContextFreeResult (ContextFreeGrammar MatchResult)
                 -- literals: match particular value of
                 | MatchStringExactResult !T.Text
                 | MatchNumberExactResult !Sci.Scientific
                 | MatchBoolExactResult !Bool
                 -- literals: match any of
                 | MatchStringResult !T.Text
                 | MatchNumberResult !Sci.Scientific
                 | MatchBoolResult !Sci.Scientific
                 -- literals: null is just null
                 | MatchNullResult
                 -- conditions
                 | MatchAnyResult MatchResult
                 | MatchOrResult (KeyMap MatchResult) Key MatchResult
                 | MatchIfThenResult MatchResult String MatchResult
                 -- funnel
                 | MatchFunnelResult MatchResult
                 | MatchFunnelKeysResult MatchResult
                 | MatchFunnelKeysUResult MatchResult
                 -- special
                 | MatchRefResult String MatchResult
                   deriving (Generic, Eq, Show)

instance ToJSON MatchResult where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON MatchResult
    -- No need to provide a parseJSON implementation.

-- MatchPattern × Value -(matchPattern)-> MatchResult

data MatchPath = ObjKey Key | ArrKey Int deriving (Generic, Eq, Show)

{-
gatherFunnel :: [Value] -> MatchPattern -> [Value]
gatherFunnel acc (MatchObjectPartialResult _ o) = L.foldl' gatherFunnel acc (KM.elems o)
gatherFunnel acc (MatchObject o) = L.foldl' gatherFunnel acc (KM.elems o) -- FIXME
gatherFunnel acc (MatchArraySomeResult _ o) = L.foldl' gatherFunnel acc (fmap snd o)
gatherFunnel acc (MatchArrayResult o) = L.foldl' gatherFunnel acc o
gatherFunnel acc (MatchArrayContextFreeResult a) = L.foldl' gatherFunnel acc a
gatherFunnel acc (MatchArrayOneResult o) = gatherFunnel acc o
gatherFunnel acc (MatchSimpleOrResult o) = gatherFunnel acc o
gatherFunnel acc (MatchFunnelResult r) = r:acc
gatherFunnel acc (MatchFunnelResultM r) = case asArray r of
                                               Nothing -> error ("aaa: " ++ show acc)
                                               Just a -> L.nub $ a ++ acc
gatherFunnel acc MatchLiteral = acc
gatherFunnel acc (MatchAnyResult _) = acc
-- gatherFunnel acc MatchIgnoreResult = acc
gatherFunnel acc (MatchString _) = acc
gatherFunnel acc (MatchNumber _) = acc
gatherFunnel acc MatchNull = acc
gatherFunnel acc x = error (show x)
--gatherFunnel acc _ = acc
-}

--matchPattern :: 

m2ms :: MatchStatus a -> Maybe a -> MatchStatus a
m2ms m v = case v of
              Just x -> MatchSuccess x
              Nothing -> m

-- pattern -> value -> result
matchPattern :: MatchPattern -> Value -> MatchStatus MatchResult -> MatchPattern -> Value -> MatchStatus MatchResult
--matchPattern (MatchMustHave m) v = case matchPattern m v of
--                                             Just x -> Just x
--                                             Nothing -> error "must have"
--

--doKeyMatch :: MatchPattern -> Value -> MatchStatus MatchResult -> KeyMap (ObjectKeyMatch MatchPattern) -> KeyMap Value -> MatchStatus (KeyMap (ObjectKeyMatch MatchResult)) -> Key -> MatchStatus (KeyMap (ObjectKeyMatch MatchResult))

--mObj :: Bool -> (a -> Value -> MatchStatus r) -> KeyMap (ObjectKeyMatch a) -> KeyMap Value -> MatchStatus (KeyMap (ObjectKeyMatch r))
mObj keepExt m a = do
  preResult <- L.foldl' (doKeyMatch m a) (MatchSuccess mempty) (keys m)
  L.foldl' f (MatchSuccess preResult) (keys a)
    where
      doKeyMatch m a acc' k = do
        acc <- acc'
        v <- (m2ms $ MatchFailure "impossible") (KM.lookup k m)
        case v of
            KeyReq r -> case KM.lookup k a of     
                              Nothing -> NoMatch $ "Required key " ++ show k ++ " not found in map"
                              Just n -> case matchPattern r n of
                                            NoMatch s -> NoMatch s
                                            MatchFailure s -> MatchFailure s
                                            MatchSuccess s -> MatchSuccess (KM.insert k (KeyReq s) acc)
            KeyOpt r -> case KM.lookup k a of     
                              Nothing -> MatchSuccess acc
                              Just n -> case matchPattern r n of
                                            NoMatch s -> NoMatch s
                                            MatchFailure s -> MatchFailure s
                                            MatchSuccess s -> MatchSuccess (KM.insert k (KeyOpt s) acc)
            KeyExt _ -> MatchFailure "malformed grammar: KeyExt cannot be here"
      f acc' k = do
            acc <- acc'
            case KM.member k m of
                 True -> MatchSuccess acc
                 False -> case keepExt of
                               False -> NoMatch "extra key in arg"
                               True -> case KM.lookup k a of
                                            Nothing -> MatchFailure "impossible"
                                            Just v -> MatchSuccess (KM.insert k (KeyExt v) acc)

matchPattern (MatchObjectFull m) (Object a) = fmap MatchObjectFullResult (mObj False m a)
matchPattern (MatchObjectPartial m) (Object a) = fmap MatchObjectPartialResult (mObj True m a)

matchPattern (MatchArrayAll m) (Array a) = do
  let vv = (V.toList a)
      f acc e = do
          acc' <- acc
          case matchPattern m e of
             MatchSuccess r -> MatchSuccess (acc' ++ [r])
             MatchFailure r -> MatchFailure r
             NoMatch _ -> MatchSuccess acc'
  acc <- L.foldl' f (MatchSuccess mempty) vv
  acc <- if P.length acc /= P.length vv then NoMatch "array length mismatch" else MatchSuccess acc
  return $ MatchArrayAllResult acc

{-
matchPattern (MatchArrayOne m) (Array a) = do
  let vv = (V.toList a)
      f acc e = do
          acc' <- acc
          case matchPattern m e of
             MatchSuccess r -> MatchSuccess (acc' ++ [r])
             MatchFailure r -> MatchFailure r
             NoMatch _ -> MatchSuccess acc'
  acc <- L.foldl' f (MatchSuccess mempty) vv
  acc <- if P.length acc /= 1 then NoMatch "array length isn't 1" else MatchSuccess acc
  return $ MatchArrayOneResult (P.head acc)

matchPattern (MatchArrayExact m) (Array a) = if P.length m /= V.length a then MatchFailure "array exact match" else do
  let f acc (p, e) = do
          acc' <- acc
          case matchPattern p e of
             MatchSuccess r -> MatchSuccess (acc' ++ [r])
             MatchFailure r -> MatchFailure r
             NoMatch r -> NoMatch r
  acc <- L.foldl' f (MatchSuccess mempty) (P.zip m (V.toList a))
  return $ MatchArrayResult acc

{-
contextFreeMatch
  :: (Eq a1, Show a1, Show a2) =>
     ContextFreeGrammar a1
     -> [a2]
     -> (a1 -> a2 -> MatchStatus a1)
     -> MatchStatus (ContextFreeGrammar a1)
-}

matchPattern (MatchArrayContextFree m) (Array a) = do
  case contextFreeMatch m (V.toList a) matchPattern of
       NoMatch e -> NoMatch ("context-free nomatch: " ++ e)
       MatchFailure s -> MatchFailure s
       MatchSuccess x -> MatchSuccess (MatchArrayContextFreeResult x)

matchPattern (MatchArrayContextFree m) (Object a) = MatchFailure ("object in cf:\n\n" ++ (TL.unpack . TL.decodeUtf8 . encode $ m) ++ "\n\n" ++ (TL.unpack . TL.decodeUtf8 . encode $ toJSON $ a))

{ -
matchPattern (MatchArrayContextFree m) (Object a) = do
  let a1 = case KM.lookup (fromString "body") a of
              Nothing -> MatchFailure "cf extra fail"
              Just v -> MatchSuccess v
  v <- a1
  v' <- case asArray v of Nothing -> MatchFailure "cf extra fail 2"; Just v -> MatchSuccess v
  let a2 = case contextFreeMatch m v' matchPattern of
             NoMatch e -> NoMatch ("context-free nomatch: " ++ e)
             MatchFailure s -> MatchFailure s
             MatchSuccess x ->  MatchSuccess (MatchArrayContextFreeResult x)
  a2
- }

matchPattern MatchFunnel v = MatchSuccess $ MatchFunnelResult v

matchPattern MatchFunnelKeys (Object v) = MatchSuccess $ MatchFunnelResult $ Array $ V.fromList $ (fmap (String . K.toText)) $ KM.keys v
matchPattern MatchFunnelKeys _ = MatchFailure "MatchFunnelKeys met not a KeyMap"

matchPattern MatchFunnelKeysU (Object v) = MatchSuccess $ MatchFunnelResultM $ Array $ V.fromList $ (fmap (String . K.toText)) $ KM.keys v
matchPattern MatchFunnelKeysU _ = MatchFailure "MatchFunnelKeys met not a KeyMap"

matchPattern (MatchIfThen baseMatch match failMsg) v =
  case matchPattern baseMatch v of
       NoMatch x -> NoMatch x
       MatchFailure f -> MatchFailure f
       MatchSuccess s -> case matchPattern match v of
                            NoMatch x -> MatchFailure (failMsg ++ show x)
                            MatchFailure f -> MatchFailure f
                            MatchSuccess s -> MatchSuccess s

matchPattern (MatchArraySome m) (Array a) = do
  let f acc (idx, e) = do
          (a1, a2) <- acc
          case matchPattern m e of
             MatchSuccess r -> (MatchSuccess (a1, a2 ++ [(idx, r)]))
             MatchFailure r -> MatchFailure r
             NoMatch _ -> MatchSuccess (a1 ++ [(idx, e)], a2)
  (a1, a2) <- L.foldl' f (MatchSuccess (mempty, mempty)) $ P.zip [0..] (V.toList a)
  --(a1, a2) <- if P.length a2 > 0 then MatchSuccess (a1, a2) else NoMatch "array mustn't be empty"
  return $ MatchArraySomeResult a1 a2

matchPattern MatchAny a = MatchSuccess $ MatchAnyResult a
-- matchPattern MatchIgnore a = MatchSuccess MatchIgnoreResult
matchPattern (MatchSimpleOr ms) v = fmap MatchSimpleOrResult $ P.foldr f (NoMatch "or fail") ms
  where f a b = case matchPattern a v of
                     MatchSuccess x -> MatchSuccess x
                     MatchFailure f -> MatchFailure f
                     _ -> b

-- valueless
--matchPattern (MatchApply (MatchOp f) m) v = matchPattern m v >>= f
matchPattern (MatchString m) (String a) = if m == a then MatchSuccess MatchLiteral else NoMatch ("string mismatch: expected " ++ show m ++ " but found " ++ show a)
matchPattern (MatchNumber m) (Number a) = if m == a then MatchSuccess MatchLiteral else NoMatch ("number mismatch: expected " ++ show m ++ " but found " ++ show a)
matchPattern (MatchBool m) (Bool a) = if m == a then MatchSuccess MatchLiteral else NoMatch ("bool mismatch: expected " ++ show m ++ " but found " ++ show a)
matchPattern MatchNull Null = MatchSuccess MatchLiteral
-- valued
matchPattern MatchLiteral (String a) = MatchSuccess $ MatchString a
matchPattern MatchLiteral (Number a) = MatchSuccess $ MatchNumber a
matchPattern MatchLiteral (Bool a) = MatchSuccess $ MatchBool a
matchPattern MatchLiteral Null = MatchSuccess $ MatchNull
-- default ca
matchPattern m a = NoMatch ("bottom reached:\n" ++ show m ++ "\n" ++ show a)

-}

-- Match functions end
{-
:{
matchPatternWithRefs
  (fromList [
    (
      "category",
       MatchObject (fromList [
        ("children", MatchArray $ MatchRef "category"),
        ("name", MatchLiteral)
       ])
    )
  ])
  (MatchRef "category")
  (Object (fromList [("name", "category1"), ("children", Array [(Object (fromList [("name", "category2"), ("children", Array [(Object (fromList [("name", "category3"), ("children", Array [])]))])]))])]))
:}
-}

{-
matchPattern
  (MatchArray
    (MatchObject
      (fromList [("name", MatchLiteral)])))
  (Array [
    Object (fromList [("name", String "apple")]),
    Object (fromList [("name", String "banana")]),
    Object (fromList [("name", String "orange")])])
MatchSuccess
  (MatchArrayResult [
    MatchObject (fromList [("name",MatchString "apple")]),
    MatchObject (fromList [("name",MatchString "banana")]),
    MatchObject (fromList [("name",MatchString "orange")])])
-}
