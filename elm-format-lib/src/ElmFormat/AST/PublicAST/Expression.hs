{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module ElmFormat.AST.PublicAST.Expression (Expression(..), Definition(..), DefinitionBuilder, TypedParameter(..), LetDeclaration(..), CaseBranch(..), mkDefinitions, fromDefinition) where

import ElmFormat.AST.PublicAST.Core
import ElmFormat.AST.PublicAST.Reference
import qualified AST.V0_16 as AST
import qualified Data.Indexed as I
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified ElmFormat.AST.PatternMatching as PatternMatching
import qualified Data.Maybe as Maybe
import ElmFormat.AST.PublicAST.Pattern
import ElmFormat.AST.PublicAST.Type
import ElmFormat.AST.PublicAST.Comment
import Data.Maybe (mapMaybe, fromMaybe)
import Data.Text (Text)
import qualified Data.Either as Either
import qualified Data.Text as Text
import qualified ElmFormat.AST.BinaryOperatorPrecedence as BinaryOperatorPrecedence


data BinaryOperation
    = BinaryOperation
        { operator :: Reference
        , term :: LocatedIfRequested Expression
        }

instance ToJSON BinaryOperation where
    toJSON = undefined
    toEncoding = \case
        BinaryOperation operator term ->
            pairs $ mconcat
                [ "operator" .= operator
                , "term" .= term
                ]


data LetDeclaration
    = LetDefinition Definition
    | Comment_ld Comment

mkLetDeclarations :: Config -> List (ASTNS Located [UppercaseIdentifier] 'LetDeclarationNK) -> List (MaybeF LocatedIfRequested LetDeclaration)
mkLetDeclarations config decls =
    let
        toDefBuilder :: ASTNS1 Located [UppercaseIdentifier] 'LetDeclarationNK -> DefinitionBuilder LetDeclaration
        toDefBuilder = \case
            AST.LetCommonDeclaration (I.Fix (A _ def)) ->
                Right def

            AST.LetComment comment ->
                Left $ Comment_ld (mkComment comment)
    in
    mkDefinitions config LetDefinition $ fmap (JustF . fmap toDefBuilder . fromLocated config . I.unFix) decls

fromLetDeclaration :: LetDeclaration -> List (ASTNS Identity [UppercaseIdentifier] 'LetDeclarationNK)
fromLetDeclaration = \case
    LetDefinition def ->
        I.Fix . Identity . AST.LetCommonDeclaration <$> fromDefinition def

    Comment_ld comment ->
        pure $ I.Fix $ Identity $ AST.LetComment (fromComment comment)


instance ToJSON LetDeclaration where
    toJSON = undefined
    toEncoding = pairs . toPairs

instance ToPairs LetDeclaration where
    toPairs = \case
        LetDefinition def ->
            toPairs def

        Comment_ld comment ->
            toPairs comment

instance FromJSON LetDeclaration where
    parseJSON = withObject "LetDeclaration" $ \obj -> do
        tag :: Text <- obj .: "tag"
        case tag of
            "Definition" ->
                LetDefinition <$> parseJSON (Object obj)

            "Comment" ->
                Comment_ld <$> parseJSON (Object obj)

            _ ->
                fail ("unexpected LetDeclaration tag: " <> Text.unpack tag)


data CaseBranch
    = CaseBranch
        { pattern_cb :: LocatedIfRequested Pattern
        , body :: MaybeF LocatedIfRequested Expression
        }

instance ToPublicAST 'CaseBranchNK where
    type PublicAST 'CaseBranchNK = CaseBranch

    fromRawAST' config = \case
        AST.CaseBranch c1 c2 c3 pat body ->
            CaseBranch
                (fromRawAST config pat)
                (JustF $ fromRawAST config body)

instance FromPublicAST 'CaseBranchNK where
    toRawAST' = \case
        CaseBranch pattern body ->
            AST.CaseBranch [] [] []
                (toRawAST pattern)
                (maybeF (I.Fix . Identity . toRawAST') toRawAST body)

instance ToPairs CaseBranch where
    toPairs = \case
        CaseBranch pattern body ->
            mconcat
                [ "pattern" .= pattern
                , "body" .= body
                ]

instance ToJSON CaseBranch where
    toJSON = undefined
    toEncoding = pairs . toPairs

instance FromJSON CaseBranch where
    parseJSON = withObject "CaseBranch" $ \obj -> do
        CaseBranch
            <$> obj .: "pattern"
            <*> obj .: "body"


data Expression
    = UnitLiteral
    | LiteralExpression LiteralValue
    | VariableReferenceExpression Reference
    | FunctionApplication
        { function :: MaybeF LocatedIfRequested Expression
        , arguments :: List (MaybeF LocatedIfRequested Expression)
        , display_fa :: FunctionApplicationDisplay
        }
    | UnaryOperator
        { operator :: AST.UnaryOperator
        }
    | ListLiteral
        { terms :: List (LocatedIfRequested Expression)
        }
    | TupleLiteral
        { terms :: List (LocatedIfRequested Expression) -- At least two items
        }
    | RecordLiteral
        { base :: Maybe LowercaseIdentifier
        , fields :: Map LowercaseIdentifier (LocatedIfRequested Expression) -- Cannot be empty if base is present
        , display_rl :: RecordDisplay
        }
    | RecordAccessFunction
        { field :: LowercaseIdentifier
        }
    | AnonymousFunction
        { parameters :: List (LocatedIfRequested Pattern) -- Non-empty
        , body :: LocatedIfRequested Expression
        }
    | LetExpression
        { declarations :: List (MaybeF LocatedIfRequested LetDeclaration)
        , body :: LocatedIfRequested Expression
        }
    | CaseExpression
        { subject :: LocatedIfRequested Expression
        , branches :: List (LocatedIfRequested CaseBranch)
        , display :: CaseDisplay
        }
    | GLShader
        { shaderSource :: String
        }


instance ToPublicAST 'ExpressionNK where
    type PublicAST 'ExpressionNK = Expression

    fromRawAST' config = \case
        AST.Unit comments ->
            UnitLiteral

        AST.Literal lit ->
            LiteralExpression lit

        AST.VarExpr var ->
            VariableReferenceExpression $ mkReference var

        AST.App expr args multiline ->
            FunctionApplication
                (JustF $ fromRawAST config expr)
                (fmap (\(C comments a) -> JustF $ fromRawAST config a) args)
                (FunctionApplicationDisplay ShowAsFunctionApplication)

        AST.Binops first rest multiline ->
            case
                BinaryOperatorPrecedence.parseElm0_19
                    first
                    ((\(AST.BinopsClause c1 op c2 expr) -> (op, expr)) <$> rest)
            of
                Right tree ->
                    extract $ buildTree tree

                Left message ->
                    error ("invalid binary operator expression: " <> Text.unpack message)
            where
                buildTree :: BinaryOperatorPrecedence.Tree (Ref [UppercaseIdentifier ]) (ASTNS Located [UppercaseIdentifier] 'ExpressionNK) -> MaybeF LocatedIfRequested Expression
                buildTree (BinaryOperatorPrecedence.Leaf e) =
                    JustF $ fromRawAST config e
                buildTree (BinaryOperatorPrecedence.Branch op e1 e2) =
                    NothingF $ FunctionApplication
                        (NothingF $ VariableReferenceExpression $ mkReference op)
                        (buildTree <$> [ e1, e2 ])
                        (FunctionApplicationDisplay ShowAsInfix)

        AST.Unary op expr ->
            FunctionApplication
                (NothingF $ UnaryOperator op)
                [ JustF $ fromRawAST config expr ]
                (FunctionApplicationDisplay ShowAsFunctionApplication)

        AST.Parens (C comments expr) ->
            fromRawAST' config $ extract $ I.unFix expr

        AST.ExplicitList terms comments multiline ->
            ListLiteral
                ((\(C comments a) -> fromRawAST config a) <$> AST.toCommentedList terms)

        AST.Tuple terms multiline ->
            TupleLiteral
                (fmap (\(C comments a) -> fromRawAST config a) terms)

        AST.TupleFunction n | n <= 1 ->
            error ("INVALID TUPLE CONSTRUCTOR: " ++ show n)

        AST.TupleFunction n ->
            VariableReferenceExpression
                (mkReference $ OpRef $ SymbolIdentifier $ replicate (n-1) ',')

        AST.Record base fields comments multiline ->
            RecordLiteral
                (fmap (\(C comments a) -> a) base)
                (Map.fromList $ (\(C cp (Pair (C ck key) (C cv value) ml)) -> (key, fromRawAST config value)) <$> AST.toCommentedList fields)
                $ RecordDisplay
                    (extract . _key . extract <$> AST.toCommentedList fields)

        AST.Access base field ->
            FunctionApplication
                (NothingF $ RecordAccessFunction field)
                [ JustF $ fromRawAST config base ]
                (FunctionApplicationDisplay ShowAsRecordAccess)

        AST.AccessFunction field ->
            RecordAccessFunction field

        AST.Lambda parameters comments body multiline ->
            AnonymousFunction
                (fmap (\(C c a) -> fromRawAST config a) parameters)
                (fromRawAST config body)

        AST.If (AST.IfClause cond' thenBody') rest' (C c3 elseBody) ->
            ifThenElse cond' thenBody' rest'
            where
                ifThenElse (C c1 cond) (C c2 thenBody) rest =
                    CaseExpression
                        (fromRawAST config cond)
                        [ LocatedIfRequested $ NothingF $ CaseBranch
                            (LocatedIfRequested $ NothingF $ DataPattern (ExternalReference (ModuleName [UppercaseIdentifier "Basics"]) (TagRef () $ UppercaseIdentifier "True")) []) $
                            JustF $ fromRawAST config thenBody
                        , LocatedIfRequested $ NothingF $ CaseBranch
                            (LocatedIfRequested $ NothingF $ DataPattern (ExternalReference (ModuleName [UppercaseIdentifier "Basics"]) (TagRef () $ UppercaseIdentifier "False")) []) $
                            case rest of
                                [] -> JustF $ fromRawAST config elseBody
                                C c4 (AST.IfClause nextCond nextBody) : nextRest ->
                                    NothingF $ ifThenElse nextCond nextBody nextRest
                        ]
                        (CaseDisplay True)

        AST.Let decls comments body ->
            LetExpression
                (mkLetDeclarations config decls)
                (fromRawAST config body)

        AST.Case (C comments subject, multiline) branches ->
            CaseExpression
                (fromRawAST config subject)
                (fromRawAST config <$> branches)
                (CaseDisplay False)

        AST.Range _ _ _ ->
            error "Range syntax is not supported in Elm 0.19"

        AST.GLShader shader ->
            GLShader shader

instance FromPublicAST 'ExpressionNK where
    toRawAST' = \case
        UnitLiteral ->
            AST.Unit []

        LiteralExpression lit ->
            AST.Literal lit

        VariableReferenceExpression var ->
            AST.VarExpr $ toRef var

        FunctionApplication function args display ->
            case (extract function, args) of
                (UnaryOperator operator, [ single ]) ->
                    AST.Unary
                        operator
                        (maybeF (I.Fix . Identity . toRawAST') toRawAST single)

                (UnaryOperator _, []) ->
                    undefined

                (UnaryOperator _, _) ->
                    error "TODO: UnaryOperator with extra arguments"

                _ ->
                    AST.App
                        (maybeF (I.Fix . Identity . toRawAST') toRawAST function)
                        (C [] . maybeF (I.Fix . Identity . toRawAST') toRawAST <$> args)
                        (AST.FAJoinFirst AST.JoinAll)

        UnaryOperator _ ->
            error "UnaryOperator is only valid as the \"function\" of a FunctionApplication node"

        ListLiteral terms ->
            AST.ExplicitList
                (Either.fromRight undefined $ AST.fromCommentedList $ C ([], [], Nothing) . toRawAST <$> terms)
                []
                (AST.ForceMultiline True)

        TupleLiteral terms ->
            AST.Tuple
                (C ([], []) . toRawAST <$> terms)
                True

        RecordLiteral base fields display ->
            AST.Record
                (C ([], []) <$> base)
                (Either.fromRight undefined $ AST.fromCommentedList $ C ([], [], Nothing) . (\(field, expression) -> Pair (C [] field) (C [] $ toRawAST expression) (AST.ForceMultiline False)) <$> Map.toList fields)
                []
                (AST.ForceMultiline True)

        RecordAccessFunction field ->
            AST.AccessFunction  field

        AnonymousFunction parameters body ->
            AST.Lambda
                (C [] . toRawAST <$> parameters)
                []
                (toRawAST body)
                False

        CaseExpression subject branches display ->
            AST.Case
                (C ([], []) $ toRawAST subject, False)
                (toRawAST <$> branches)

        LetExpression declarations body ->
            AST.Let
                (mconcat $ fmap (fromLetDeclaration . extract) declarations)
                []
                (toRawAST body)

        GLShader shaderSource ->
            AST.GLShader shaderSource


instance ToJSON Expression where
    toJSON = undefined
    toEncoding = pairs . toPairs

instance ToPairs Expression where
    toPairs = \case
        UnitLiteral ->
            mconcat
                [ type_ "UnitLiteral"
                ]

        LiteralExpression lit ->
            toPairs lit

        VariableReferenceExpression ref ->
            toPairs ref

        FunctionApplication function arguments display ->
            mconcat $ Maybe.catMaybes
                [ Just $ type_ "FunctionApplication"
                , Just $ "function" .= function
                , Just $ "arguments" .= arguments
                , pair "display" <$> toMaybeEncoding display
                ]

        UnaryOperator operator ->
            mconcat
                [ type_ "UnaryOperator"
                , "operator" .= operator
                ]

        ListLiteral terms ->
            mconcat
                [ type_ "ListLiteral"
                , "terms" .= terms
                ]

        TupleLiteral terms ->
            mconcat
                [ type_ "TupleLiteral"
                , "terms" .= terms
                ]

        RecordLiteral Nothing fields display ->
            mconcat
                [ type_ "RecordLiteral"
                , "fields" .= fields
                , "display" .= display
                ]

        RecordLiteral (Just base) fields display ->
            mconcat
                [ type_ "RecordUpdate"
                , "base" .= base
                , "fields" .= fields
                , "display" .= display
                ]

        RecordAccessFunction field ->
            mconcat
                [ type_ "RecordAccessFunction"
                , "field" .= field
                ]

        AnonymousFunction parameters body ->
            mconcat
                [ type_ "AnonymousFunction"
                , "parameters" .= parameters
                , "body" .= body
                ]

        LetExpression declarations body ->
            mconcat
                [ type_ "LetExpression"
                , "declarations" .= declarations
                , "body" .= body
                ]

        CaseExpression subject branches display ->
            mconcat $ Maybe.catMaybes
                [ Just $ type_ "CaseExpression"
                , Just $ "subject" .= subject
                , Just $ "branches" .= branches
                , pair "display" <$> toMaybeEncoding display
                ]

        GLShader shaderSource ->
            mconcat
                [ type_ "GLShader"
                , "shaderSource" .= shaderSource
                ]

instance FromJSON Expression where
    parseJSON = withObject "Expression" $ \obj -> do
        tag :: Text <- obj .: "tag"
        case tag of
            "UnitLiteral" ->
                return UnitLiteral

            "IntLiteral" ->
                LiteralExpression <$> parseJSON (Object obj)

            "FloatLiteral" ->
                LiteralExpression <$> parseJSON (Object obj)

            "StringLiteral" ->
                LiteralExpression <$> parseJSON (Object obj)

            "CharLiteral" ->
                LiteralExpression <$> parseJSON (Object obj)

            "VariableReference" ->
                VariableReferenceExpression <$> parseJSON (Object obj)

            "ExternalReference" ->
                VariableReferenceExpression <$> parseJSON (Object obj)

            "FunctionApplication" ->
                FunctionApplication
                    <$> obj .: "function"
                    <*> obj .: "arguments"
                    <*> return (FunctionApplicationDisplay ShowAsFunctionApplication)

            "UnaryOperator" ->
                UnaryOperator
                    <$> obj .: "operator"

            "ListLiteral" ->
                ListLiteral
                    <$> obj .: "terms"

            "TupleLiteral" ->
                TupleLiteral
                    <$> obj .: "terms"

            "RecordLiteral" ->
                RecordLiteral Nothing
                    <$> obj .: "fields"
                    <*> return (RecordDisplay [])

            "RecordUpdate" ->
                RecordLiteral
                    <$> (Just <$> obj .: "base")
                    <*> obj .: "fields"
                    <*> return (RecordDisplay [])

            "RecordAccessFunction" ->
                RecordAccessFunction
                    <$> obj .: "field"

            "AnonymousFunction" ->
                AnonymousFunction
                    <$> obj .: "parameters"
                    <*> obj .: "body"

            "CaseExpression" ->
                CaseExpression
                    <$> obj .: "subject"
                    <*> obj .: "branches"
                    <*> return (CaseDisplay False)

            "LetExpression" ->
                LetExpression
                    <$> obj .: "declarations"
                    <*> obj .: "body"

            "GLShader" ->
                GLShader
                    <$> obj .: "shaderSource"

            _ ->
                return $ LiteralExpression $ Str ("TODO: " <> show (Object obj)) SingleQuotedString


newtype FunctionApplicationDisplay
    = FunctionApplicationDisplay
        { showAs :: FunctionApplicationShowAs
        }

instance ToMaybeJSON FunctionApplicationDisplay where
    toMaybeEncoding = \case
        FunctionApplicationDisplay showAs ->
            case
                Maybe.catMaybes
                    [ case showAs of
                        ShowAsRecordAccess -> Just ("showAsRecordAccess" .= True)
                        ShowAsInfix -> Just ("showAsInfix" .= True)
                        ShowAsFunctionApplication -> Nothing
                    ]
            of
                [] -> Nothing
                some -> Just $ pairs $ mconcat some


data FunctionApplicationShowAs
    = ShowAsRecordAccess
    | ShowAsInfix
    | ShowAsFunctionApplication


newtype CaseDisplay
    = CaseDisplay
        { showAsIf :: Bool
        }
    deriving (Generic)

instance ToMaybeJSON CaseDisplay where
    toMaybeEncoding = \case
        CaseDisplay showAsIf ->
            case
                Maybe.catMaybes
                    [ if showAsIf
                        then Just ("showAsIf" .= True)
                        else Nothing
                    ]
            of
                [] -> Nothing
                some -> Just $ pairs $ mconcat some


--
-- Definition
--


data TypedParameter
    = TypedParameter
        { pattern_tp :: LocatedIfRequested Pattern
        , type_tp :: Maybe (LocatedIfRequested Type_)
        }

instance ToJSON TypedParameter where
    toJSON = undefined
    toEncoding = \case
        TypedParameter pattern typ ->
            pairs $ mconcat
                [ "pattern" .= pattern
                , "type" .= typ
                ]

instance FromJSON TypedParameter where
    parseJSON = withObject "TypedParameter" $ \obj ->
        TypedParameter
            <$> obj .: "pattern"
            <*> obj .:? "type"


data Definition
    = Definition
        { name_d :: LowercaseIdentifier
        , parameters_d :: List TypedParameter
        , returnType :: Maybe (LocatedIfRequested Type_)
        , expression :: LocatedIfRequested Expression
        }
    | TODO_Definition (List String)

mkDefinition ::
    Config
    -> ASTNS1 Located [UppercaseIdentifier] 'PatternNK
    -> List (AST.C1 'AST.BeforeTerm (ASTNS Located [UppercaseIdentifier] 'PatternNK))
    -> Maybe (AST.C2 'AST.BeforeSeparator 'AST.AfterSeparator (ASTNS Located [UppercaseIdentifier] 'TypeNK))
    -> ASTNS Located [UppercaseIdentifier] 'ExpressionNK
    -> Definition
mkDefinition config pat args annotation expr =
    case pat of
        AST.VarPattern name ->
            let
                (typedParams, returnType) =
                    maybe
                        ( fmap (, Nothing) args, Nothing )
                        ((\(a,b) -> ( fmap (fmap Just) a, Just b )) . PatternMatching.matchType args . (\(C (c1, c2) t) -> t))
                        annotation
            in
            Definition
                name
                (fmap (\(C c pat, typ) -> TypedParameter (fromRawAST config pat) (fmap (fromRawAST config) typ)) typedParams)
                (fmap (fromRawAST config) returnType)
                (fromRawAST config expr)

        _ ->
            TODO_Definition
                [ show pat
                , show args
                , show annotation
                , show expr
                ]

fromDefinition :: Definition -> List (ASTNS Identity [UppercaseIdentifier] 'CommonDeclarationNK)
fromDefinition = \case
    Definition name parameters Nothing expression ->
        pure $ I.Fix $ Identity $ AST.Definition
            (I.Fix $ Identity $ AST.VarPattern name)
            (C [] . toRawAST . pattern_tp <$> parameters)
            []
            (toRawAST expression)

    Definition name [] (Just typ) expression ->
        [ I.Fix $ Identity $ AST.TypeAnnotation
            (C [] $ VarRef () name)
            (C [] $ toRawAST typ)
        , I.Fix $ Identity $ AST.Definition
            (I.Fix $ Identity $ AST.VarPattern name)
            []
            []
            (toRawAST expression)
        ]

    Definition name parameters (Just typ) expression ->
        [ I.Fix $ Identity $ AST.TypeAnnotation
            (C [] $ VarRef () name)
            (C [] $ toRawAST $ LocatedIfRequested $ NothingF $ FunctionType typ (fromMaybe (LocatedIfRequested $ NothingF UnitType) . type_tp <$> parameters))
        , I.Fix $ Identity $ AST.Definition
            (I.Fix $ Identity $ AST.VarPattern name)
            (C [] . toRawAST . pattern_tp <$> parameters)
            []
            (toRawAST expression)
        ]

type DefinitionBuilder a
    = Either a (ASTNS1 Located [UppercaseIdentifier] 'CommonDeclarationNK)

mkDefinitions ::
    forall a.
    Config
    -> (Definition -> a)
    -> List (MaybeF LocatedIfRequested (DefinitionBuilder a))
    -> List (MaybeF LocatedIfRequested a)
mkDefinitions config fromDef items =
    let
        collectAnnotation :: DefinitionBuilder a -> Maybe (LowercaseIdentifier, AST.C2 'AST.BeforeSeparator 'AST.AfterSeparator (ASTNS Located [UppercaseIdentifier] 'TypeNK))
        collectAnnotation decl =
            case decl of
                Right (AST.TypeAnnotation (C preColon (VarRef () name)) (C postColon typ)) ->
                    Just (name, C (preColon, postColon) typ)
                _ -> Nothing

        annotations :: Map LowercaseIdentifier (AST.C2 'AST.BeforeSeparator 'AST.AfterSeparator (ASTNS Located [UppercaseIdentifier] 'TypeNK))
        annotations =
            Map.fromList $ mapMaybe (collectAnnotation . extract) items

        merge :: DefinitionBuilder a -> Maybe a
        merge decl =
            case decl of
                Right (AST.Definition (I.Fix (A _ pat)) args comments expr) ->
                    let
                        annotation =
                            case pat of
                                AST.VarPattern name ->
                                    Map.lookup name annotations
                                _ -> Nothing
                    in
                    Just $ fromDef $ mkDefinition config pat args annotation expr

                Right (AST.TypeAnnotation _ _) ->
                    -- TODO: retain annotations that don't have a matching definition
                    Nothing

                Left a ->
                    Just a
    in
    mapMaybe (traverse merge) items

instance ToJSON Definition where
    toJSON = undefined
    toEncoding = pairs . toPairs

instance ToPairs Definition where
    toPairs = \case
        Definition name parameters returnType expression ->
            mconcat
                [ type_ "Definition"
                , "name" .= name
                , "parameters" .= parameters
                , "returnType" .= returnType
                , "expression" .= expression
                ]

        TODO_Definition info ->
            mconcat
                [ type_ "TODO: Definition"
                , "$" .= info
                ]

instance FromJSON Definition where
    parseJSON = withObject "Definition" $ \obj -> do
        tag <- obj .: "tag"
        case tag of
            "Definition" ->
                Definition
                    <$> obj .: "name"
                    <*> obj .:? "parameters" .!= []
                    <*> obj .:? "returnType"
                    <*> obj .: "expression"

            _ ->
                fail ("unexpected Definition tag: " <> tag)

