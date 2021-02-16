{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
module ElmFormat.AST.Shared where

{-| This module contains types that are used by multiple versions of the Elm AST.
-}

import Data.Coapplicative
import Data.Int (Int64)


type List a = [a]


data LowercaseIdentifier =
    LowercaseIdentifier String
    deriving (Eq, Ord)

instance Show LowercaseIdentifier where
    show (LowercaseIdentifier name) = name


data UppercaseIdentifier =
    UppercaseIdentifier String
    deriving (Eq, Ord, Show)


data SymbolIdentifier =
    SymbolIdentifier String
    deriving (Eq, Ord, Show)


data Commented c a =
    C c a
    deriving (Eq, Ord, Functor, Show) -- TODO: is Ord needed?

instance Coapplicative (Commented c) where
    extract (C _ a) = a
    {-# INLINE extract #-}


data IntRepresentation
  = DecimalInt
  | HexadecimalInt
  deriving (Eq, Show)


data FloatRepresentation
  = DecimalFloat
  | ExponentFloat
  deriving (Eq, Show)


data StringRepresentation
    = SingleQuotedString
    | TripleQuotedString
    deriving (Eq, Show)


data LiteralValue
    = IntNum Int64 IntRepresentation
    | FloatNum Double FloatRepresentation
    | Chr Char
    | Str String StringRepresentation
    | Boolean Bool
    deriving (Eq, Show)


data Ref ns
    = VarRef ns LowercaseIdentifier
    | TagRef ns UppercaseIdentifier
    | OpRef SymbolIdentifier
    deriving (Eq, Ord, Show, Functor)


data UnaryOperator =
    Negative
    deriving (Eq, Show)