{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
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
import Data.Functor.Foldable.TH (makeBaseFunctor)

--
-- MatchStatus is a monad for representing match outcome similar to Either
--

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

data ContextFreeGrammar a = Char a
                          | Seq [(ContextFreeGrammar a)]
                          | Or (KeyMap (ContextFreeGrammar a))
                          | Star (ContextFreeGrammar a)
                          | Plus (ContextFreeGrammar a)
                          | Optional (ContextFreeGrammar a)
                            deriving (Generic, Eq, Show, Functor, Foldable, Traversable)

makeBaseFunctor ''ContextFreeGrammar

data ContextFreeGrammarResult g r = CharNode r
                                  | SeqNode [(ContextFreeGrammarResult g r)]
                                  | StarNode [(ContextFreeGrammarResult g r)]
                                  | PlusNode [(ContextFreeGrammarResult g r)]
                                  | OrNode (KeyMap (ContextFreeGrammar g)) Key (ContextFreeGrammarResult g r)
                                  | OptionalNodeValue (ContextFreeGrammarResult g r)
                                  | OptionalNodeEmpty (ContextFreeGrammar g)
                                    deriving (Generic, Eq, Show, Functor, Foldable, Traversable)

makeBaseFunctor ''ContextFreeGrammarResult

instance ToJSON a => ToJSON (ContextFreeGrammar a) where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON a => FromJSON (ContextFreeGrammar a)

instance (ToJSON g, ToJSON r) => ToJSON (ContextFreeGrammarResult g r) where
    toEncoding = genericToEncoding defaultOptions

instance (FromJSON g, FromJSON r) => FromJSON (ContextFreeGrammarResult g r)

contextFreeMatch' :: (Show g, Show v) => ContextFreeGrammar g -> [v] -> (g -> v -> MatchStatus r) -> MatchStatus ([v], (ContextFreeGrammarResult g r))
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

contextFreeMatch' (Or as) xs matchFn = L.foldr f (NoMatch "or mismatch") (KM.toList as)
  where f (opt, a) b = do
          case contextFreeMatch' a xs matchFn of
               NoMatch _ -> b
               MatchFailure s -> MatchFailure s
               MatchSuccess (xs', r) -> MatchSuccess (xs', OrNode (KM.delete opt as) opt r)

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
       NoMatch _ -> MatchSuccess (xs, OptionalNodeEmpty a)
       MatchFailure s -> MatchFailure s
       MatchSuccess (xs', subresult) -> MatchSuccess (xs', OptionalNodeValue subresult)

contextFreeMatch' a xs _ = error ("no match for: " ++ (show a) ++ " " ++ (show xs))

contextFreeMatch :: (Show g, Show v) => ContextFreeGrammar g -> [v] -> (g -> v -> MatchStatus r) -> MatchStatus (ContextFreeGrammarResult g r)
contextFreeMatch a xs matchFn = do
  (rest, result) <- contextFreeMatch' a xs matchFn
  case P.length rest == 0 of
       False -> NoMatch ("rest left: " ++ show rest)
       True -> MatchSuccess result

-- helpers. Regular

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

-- helpers. Aeson

asKeyMap :: Value -> Maybe Object
asKeyMap (Object a) = Just a
asKeyMap _ = Nothing

asArray :: Value -> Maybe [Value]
asArray (Array a) = Just $ Data.Vector.Generic.toList a
asArray _ = Nothing

asString (String x) = Just x
asString _ = Nothing

--- Helper types

--- Indicating if matching a key in an Object is obligatory
data ObjectKeyMatch a = KeyReq a | KeyOpt a | KeyExt Value deriving (Generic, Eq, Show, Functor, Foldable, Traversable)

instance ToJSON a => ToJSON (ObjectKeyMatch a) where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON a => FromJSON (ObjectKeyMatch a)
    -- No need to provide a parseJSON implementation.

--- Indicating if an element were matched or ignored (when only some must match)
data ArrayValMatch a = MatchedVal a | ExtraVal Value deriving (Generic, Eq, Show, Functor, Foldable, Traversable)

instance ToJSON a => ToJSON (ArrayValMatch a) where
    toEncoding = genericToEncoding defaultOptions

instance FromJSON a => FromJSON (ArrayValMatch a)
    -- No need to provide a parseJSON implementation.


-- Match<What>[<How>], Match<What>[<How>]Result

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
                  | MatchStringAny
                  | MatchNumberAny
                  | MatchBoolAny
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

makeBaseFunctor ''MatchPattern

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
                 | MatchArrayContextFreeResult (ContextFreeGrammarResult MatchPattern MatchResult)
                 -- literals: match particular value of
                 | MatchStringExactResult !T.Text
                 | MatchNumberExactResult !Sci.Scientific
                 | MatchBoolExactResult !Bool
                 -- literals: match any of
                 | MatchStringAnyResult !T.Text
                 | MatchNumberAnyResult !Sci.Scientific
                 | MatchBoolAnyResult !Bool
                 -- literals: null is just null
                 | MatchNullResult
                 -- conditions
                 | MatchAnyResult Value
                 | MatchOrResult (KeyMap MatchPattern) Key MatchResult
                 | MatchIfThenResult MatchResult String MatchResult
                 -- funnel
                 | MatchFunnelResult Value
                 | MatchFunnelKeysResult (KeyMap Value)
                 | MatchFunnelKeysUResult (KeyMap Value)
                 -- special
                 | MatchRefResult String MatchResult
                   deriving (Generic, Eq, Show)


makeBaseFunctor ''MatchResult

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

--
-- Convert Maybe to MatchStatus (e.g. a result of KM.lookup)
--

m2ms :: MatchStatus a -> Maybe a -> MatchStatus a
m2ms m v = case v of
              Just x -> MatchSuccess x
              Nothing -> m

-- pattern -> value -> result. result = value × pattern (is a product)
-- Both pattern and value can be derived from a result using trivial projections
-- (look category theory product)
matchPattern :: MatchPattern -> Value -> MatchStatus MatchResult

mObj keepExt m a = do
  preResult <- L.foldl' (doKeyMatch m a) (MatchSuccess mempty) (keys m)
  L.foldl' f (MatchSuccess preResult) (keys a)
    where
      step k r acc req = case KM.lookup k a of
                      Nothing -> if req
                                      then NoMatch $ "Required key " ++ show k ++ " not found in map"
                                      else MatchSuccess acc
                      Just n -> case matchPattern r n of
                                     NoMatch s -> NoMatch s
                                     MatchFailure s -> MatchFailure s
                                     MatchSuccess s -> MatchSuccess (KM.insert k el acc)
                                        where
                                          el = if req then (KeyReq s) else (KeyOpt s)
      doKeyMatch m a acc' k = do
        acc <- acc'
        v <- (m2ms $ MatchFailure "impossible") (KM.lookup k m)
        case v of
            KeyReq r -> step k r acc True
            KeyOpt r -> step k r acc False
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
  acc <- if P.length acc /= P.length vv then NoMatch "Array length mismatch" else MatchSuccess acc
  return $ MatchArrayAllResult (V.fromList acc)

matchPattern (MatchArrayOne m) (Array a) = do
  let vv = (V.toList a)
      f acc e = do
          acc' <- acc
          case matchPattern m e of
             MatchSuccess r -> MatchSuccess (acc' ++ [r])
             MatchFailure r -> MatchFailure r
             NoMatch _ -> MatchSuccess acc'
  acc <- L.foldl' f (MatchSuccess mempty) vv
  acc <- if P.length acc /= 1 then NoMatch "Array length isn't 1" else MatchSuccess acc
  return $ MatchArrayOneResult (P.head acc)

matchPattern (MatchArrayExact m) (Array a) = if P.length m /= V.length a then MatchFailure "Array exact match" else do
  let f acc (p, e) = do
          acc' <- acc
          case matchPattern p e of
             MatchSuccess r -> MatchSuccess (acc' ++ [r])
             MatchFailure r -> MatchFailure r
             NoMatch r -> NoMatch r
  acc <- L.foldl' f (MatchSuccess mempty) (P.zip m (V.toList a))
  return $ MatchArrayExactResult acc

matchPattern (MatchArrayContextFree m) (Array a) = do
  case contextFreeMatch m (V.toList a) matchPattern of
       NoMatch e -> NoMatch ("context-free nomatch: " ++ e)
       MatchFailure s -> MatchFailure s
       MatchSuccess x -> MatchSuccess (MatchArrayContextFreeResult x)

matchPattern (MatchArrayContextFree m) (Object a) = MatchFailure ("object in cf:\n\n" ++ (TL.unpack . TL.decodeUtf8 . encode $ m) ++ "\n\n" ++ (TL.unpack . TL.decodeUtf8 . encode $ toJSON $ a))

{-
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
-}

matchPattern MatchFunnel v = MatchSuccess $ MatchFunnelResult v

matchPattern MatchFunnelKeys (Object v) = MatchSuccess $ MatchFunnelKeysResult $ v
matchPattern MatchFunnelKeys _ = MatchFailure "MatchFunnelKeys met not an Object"

matchPattern MatchFunnelKeysU (Object v) = MatchSuccess $ MatchFunnelKeysUResult $ v
matchPattern MatchFunnelKeysU _ = MatchFailure "MatchFunnelKeysU met not an Object"

matchPattern (MatchIfThen baseMatch match failMsg) v =
  case matchPattern baseMatch v of
       NoMatch x -> NoMatch x
       MatchFailure f -> MatchFailure f
       MatchSuccess s -> case matchPattern match v of
                            NoMatch x -> MatchFailure (failMsg ++ show x)
                            MatchFailure f -> MatchFailure f
                            MatchSuccess s -> MatchSuccess s

matchPattern (MatchArraySome m) (Array a) = do
  let f acc' e = do
          acc <- acc'
          case matchPattern m e of
             MatchSuccess r -> MatchSuccess $ acc ++ [(MatchedVal r)]
             MatchFailure r -> MatchFailure r
             NoMatch _ -> MatchSuccess $ acc ++ [(ExtraVal e)]
  a1 <- L.foldl' f (MatchSuccess mempty) a
  return $ MatchArraySomeResult (V.fromList a1)

matchPattern MatchAny a = MatchSuccess $ MatchAnyResult a
-- matchPattern MatchIgnore a = MatchSuccess MatchIgnoreResult
matchPattern (MatchOr ms) v = do
  let f (k, a) b = case matchPattern a v of
                     MatchSuccess x -> MatchSuccess (k, x)
                     MatchFailure f -> MatchFailure f
                     _ -> b
  (k, res) <- P.foldr f (NoMatch "or fail") (KM.toList ms)
  return $ MatchOrResult (KM.delete k ms) k res

-- specific (aka exact)
matchPattern (MatchStringExact m) (String a) = if m == a then MatchSuccess $ MatchStringExactResult a else NoMatch ("string mismatch: expected " ++ show m ++ " but found " ++ show a)
matchPattern (MatchNumberExact m) (Number a) = if m == a then MatchSuccess $ MatchNumberExactResult a else NoMatch ("number mismatch: expected " ++ show m ++ " but found " ++ show a)
matchPattern (MatchBoolExact m) (Bool a) = if m == a then MatchSuccess $ MatchBoolExactResult a else NoMatch ("bool mismatch: expected " ++ show m ++ " but found " ++ show a)
-- any (of a type)
matchPattern MatchStringAny (String a) = MatchSuccess $ MatchStringAnyResult a
matchPattern MatchNumberAny (Number a) = MatchSuccess $ MatchNumberAnyResult a
matchPattern MatchBoolAny (Bool a) = MatchSuccess $ MatchBoolAnyResult a
-- null is just null
matchPattern MatchNull Null = MatchSuccess MatchNullResult
-- default ca
matchPattern m a = NoMatch ("bottom reached:\n" ++ show m ++ "\n" ++ show a)

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