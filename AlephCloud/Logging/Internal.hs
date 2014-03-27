{-# LANGUAGE RecordWildCards, OverloadedStrings, PatternGuards #-}
module AlephCloud.Logging.Internal
  (tshow,
   tshowStatus,
   hideSecrets)
  where

import Data.Array ((!))
import Data.List (foldl')
import Data.Monoid.Unicode
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Network.HTTP.Types.Status as HTTP
import Text.Regex.TDFA
import Text.Regex.TDFA.Text ({- RegexLike Regex T.Text -})


-- -------------------------------------------------------------------------- --
-- Private utilities, not exported

tshow :: (Show a) => a -> Text.Text
tshow = Text.pack . show

tshowStatus :: HTTP.Status -> Text.Text
tshowStatus HTTP.Status{..} = tshow statusCode ⊕ "(" ⊕ Text.decodeUtf8 statusMessage ⊕ ")"

-- | This is very inefficient but more maintainable and cleaner than doing it at
-- construction time, since there is a lot of generic code that constructs
-- log messages out of arbitrary data. An alternative would be to introduce
-- security labels to all contexts and make serialization of data structures
-- depend on it.
--
-- Beside this conceptual inefficiency the algorithm itself is very inefficient,
-- too, by using regular expression to do substitution one by one.
--
hideSecrets :: Text.Text -> Text.Text
hideSecrets message = foldl run message pwdPatterns
    where
    run msg pat = fst . foldl' subst (msg, 0) . matchAll pat $ msg
    subst (msg, e) mat | (o,l) <- mat ! 1 = (Text.take (o + e) msg ⊕ hide ⊕ Text.drop (o + e + l) msg, e + lh - l)
                       | otherwise = (msg, 0)
    hide = "******"
    lh = Text.length hide
    pwdPatterns :: [Regex]
    pwdPatterns = map makeRegex patterns2 ⊕ map (makeRegex . makePattern)
        [ "password" :: Text.Text
        , "pwd"
        , "passwd"
        , "aauth"
        , "bauth"
        , "group_code"
        , "auth_code"
        , "token"
        , "answer"
        ]
    makePattern x = "\"[^\"]*" ⊕ x ⊕ "[^\"]*\"[[:space:]]*:[[:space:]]*\"([^\"]+)\"" :: Text.Text
    patterns2 = ["token ([A-Za-z0-9_-]+)"] :: [Text.Text]
