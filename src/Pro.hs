{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE UnicodeSyntax #-}
module Pro where
import Control.Arrow
import Data.Function
import Data.Profunctor
-- show
type Limits a = Limits' a a
data Limits' a b = Limits
    { step ∷ a → (b, b)
    , check ∷ a → a → Bool } 

instance Profunctor Limits' where
    dimap g h Limits {..} = Limits
        { step = (h *** h) . step . g
        , check = check `on` g }

maybeLimit ∷ a → Limits a → Limits (Maybe a)
maybeLimit d = dimap (maybe d id) Just

millionsLimit ∷ Limits Double → Limits Double
millionsLimit = dimap (1.0e6 *) (/ 1.0e6)
-- /show

