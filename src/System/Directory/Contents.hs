{-# language DeriveFoldable #-}
{-# language DeriveFunctor #-}
{-# language DeriveGeneric #-}
{-# language DeriveTraversable #-}
{-# language LambdaCase #-}
{-# language MultiWayIf #-}
{-# language ScopedTypeVariables #-}

{-|
Description:
  Recursively list the contents of a directory while avoiding
  symlink loops.

Modeled after the linux @tree@ command (when invoked with the follow-symlinks
option), this module recursively lists the contents of a directory while
avoiding symlink loops. See the documentation of 'buildDirTree' for an example.

In addition to building the directory-contents tree, this module provides
facilities for filtering, displaying, and navigating the directory hierarchy.

-}
module System.Directory.Contents where

import Control.Applicative
import Control.Monad
import Data.List
import qualified Data.Map as Map
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import Data.Tree as DataTree
import Data.Witherable
import GHC.Generics
import System.Directory
import System.FilePath

-- | The contents of a directory, represented as a tree. See 'Symlink' for
-- special handling of symlinks.
data DirTree a
  = DirTree_Dir FilePath [DirTree a]
  | DirTree_File FilePath a
  | DirTree_Symlink FilePath (Symlink a)
  deriving (Show, Read, Eq, Ord, Functor, Foldable, Traversable, Generic)

-- | Symlink cycles are prevented by separating symlinks into two categories:
-- those that point to paths already within the directory hierarchy being
-- recursively listed, and those that are not. In the former case, rather than
-- following the symlink and listing the target redundantly, we simply store
-- the symlink reference itself. In the latter case, we treat the symlink as we
-- would any other folder and produce a list of its contents.
--
-- The 'String' argument represents the symlink reference (e.g., "../somefile").
data Symlink a
  = Symlink_Internal String FilePath
  | Symlink_External String [DirTree a]
  deriving (Show, Read, Eq, Ord, Functor, Foldable, Traversable, Generic)

-- * Constructing a tree
-- | Recursively list the contents of a 'FilePath', representing the results as
-- a hierarchical 'DirTree'. This function should produce results similar to
-- the linux command @tree -l@.
--
-- For example, given this directory and symlink structure
-- (as shown by @tree -l@):
--
-- > test
-- > ├── A
-- > │   ├── a
-- > │   ├── A -> ../A  [recursive, not followed]
-- > │   └── B -> ../B
-- > │       ├── A -> ../A  [recursive, not followed]
-- > │       └── b
-- > ├── B
-- > │   ├── A -> ../A  [recursive, not followed]
-- > │   └── b
-- > └── C -> ../C
-- >     └── c
--
-- this function will produce the following (as rendererd by 'drawDirTree'):
--
-- > test
-- > |
-- > +- A
-- > |  |
-- > |  +- A -> ../A
-- > |  |
-- > |  +- B -> ../B
-- > |  |
-- > |  `- a
-- > |
-- > +- B
-- > |  |
-- > |  +- A -> ../A
-- > |  |
-- > |  `- b
-- > |
-- > `- C -> ../C
-- >    |
-- >    `- c
--
buildDirTree :: FilePath -> IO (Maybe (DirTree FilePath))
buildDirTree root = build Map.empty root
  where
    build seen path = do
      canon <- canonicalizePath path
      isPath <- doesPathExist path
      isDir <- doesDirectoryExist path
      isSym <- pathIsSymbolicLink path
      subpaths <- if isDir then listDirectory path else pure []
      subcanons <- mapM canonicalizePath <=<
        filterM (fmap not . pathIsSymbolicLink) $ (path </>) <$> subpaths
      let seen' = Map.union seen $ Map.fromList $ zip subcanons subpaths
          buildSubpaths = catMaybes <$> mapM
            (build (Map.insert canon path seen') . (path </>)) subpaths
      if | not isPath -> pure Nothing
         | isSym -> case Map.lookup canon seen' of
             Nothing -> do
               s <- getSymbolicLinkTarget path
               Just . DirTree_Symlink path . Symlink_External s <$> buildSubpaths
             Just _ -> do
               target <- getSymbolicLinkTarget path
               canonRoot <- canonicalizePath root
               let startingPoint = takeFileName root
               canonSym <- canonicalizePath $ takeDirectory path </> target
               pure $ Just $ DirTree_Symlink path $ Symlink_Internal target $
                startingPoint </> mkRelative canonRoot canonSym
         | isDir -> Just . DirTree_Dir path <$> buildSubpaths
         | otherwise -> pure $ Just $ DirTree_File path path

-- | De-reference one layer of symlinks
{- |
==== __Example__

Given:

> tmp
> |
> +- A
> |  |
> |  `- a
> |
> +- a -> A/a
> |
> `- C
>    |
>    `- A -> ../A

This function will follow one level of symlinks, producing:

> tmp
> |
> +- A
> |  |
> |  `- a
> |
> +- a
> |
> `- C
>    |
>    `- A
>       |
>       `- a

-}
dereferenceSymlinks :: DirTree FilePath -> IO (DirTree FilePath)
dereferenceSymlinks toppath = deref toppath toppath
  where
    deref top cur = case cur of
      DirTree_Dir p xs -> DirTree_Dir p <$> mapM (deref top) xs
      DirTree_File p x -> pure $ DirTree_File p x
      DirTree_Symlink p sym -> case sym of
        Symlink_External _ paths -> pure $ DirTree_Dir p paths
        Symlink_Internal _ r -> do
          let startingPoint = takeFileName $ filePath top
          let target = walkDirTree (startingPoint </> r) top
          pure $ case target of
            Nothing -> DirTree_Symlink p sym
            Just t -> t

-- * Navigate
-- | Starting from the root directory, try to walk the given filepath and return
-- the 'DirTree' at the end of the route. For example, given the following tree:
--
-- > src
-- > └── System
-- >     └── Directory
-- >             └── Contents.hs
--
-- @walkDirTree "src/System"@ should produce
--
-- > Directory
-- > |
-- > `- Contents.hs
--
-- This function does not dereference symlinks, nor does it handle the special
-- paths @.@ and @..@.
walkDirTree :: FilePath -> DirTree a -> Maybe (DirTree a)
walkDirTree target p =
  let pathSegments = splitDirectories target
      walk :: [FilePath] -> DirTree a -> Maybe (DirTree a)
      walk [] path = Just path
      walk (c : gc) path = case path of
        DirTree_Dir a xs
          | takeFileName a == c -> alternative $ walk gc <$> xs
        DirTree_File a f
          | takeFileName a == c && null gc -> Just $ DirTree_File a f
        DirTree_Symlink a (Symlink_Internal s t)
          | takeFileName a == c && null gc -> Just $ DirTree_Symlink a
            (Symlink_Internal s t)
        DirTree_Symlink a (Symlink_External _ xs)
          | takeFileName a == c -> alternative $ walk gc <$> xs
        _ -> Nothing
  in walk pathSegments p

-- | Like 'walkDirTree' but skips the outermost containing directory. Useful for
-- walking paths relative from the root directory passed to 'buildDirTree'.
--
-- Given the following 'DirTree':
--
-- > src
-- > └── System
-- >     └── Directory
-- >             └── Contents.hs
--
-- @walkContents "System"@ should produce
--
-- > Directory
-- > |
-- > `- Contents.hs
walkContents :: FilePath -> DirTree a -> Maybe (DirTree a)
walkContents p = \case
  DirTree_Dir _ xs -> walkSub xs
  DirTree_File _ _ -> Nothing
  DirTree_Symlink _ (Symlink_External _ xs) -> walkSub xs
  DirTree_Symlink _ (Symlink_Internal _ _) -> Nothing
  where
    walkSub :: [DirTree a] -> Maybe (DirTree a)
    walkSub xs = getAlt $ mconcat $ Alt . walkDirTree p <$> xs

-- * Filter
-- | This wrapper really just represents the no-path/empty case so that
-- filtering works
newtype DirTreeMaybe a = DirTreeMaybe { unDirTreeMaybe :: Maybe (DirTree a) }
  deriving (Show, Read, Eq, Ord, Functor, Foldable, Traversable)

instance Filterable DirTreeMaybe where
  catMaybes (DirTreeMaybe Nothing) = DirTreeMaybe Nothing
  catMaybes (DirTreeMaybe (Just x)) = DirTreeMaybe $
    let go :: DirTree (Maybe a) -> Maybe (DirTree a)
        go = \case
          DirTree_Dir p xs -> Just $ DirTree_Dir p $ catMaybes $ go <$> xs
          DirTree_File p f -> DirTree_File p <$> f
          DirTree_Symlink p (Symlink_External s f) -> Just $ DirTree_Symlink p
            (Symlink_External s $ mapMaybe go f)
          DirTree_Symlink p (Symlink_Internal s t) ->
            case go <$> walkDirTree t x of
              Nothing -> Nothing
              Just Nothing -> Nothing
              Just (Just _) -> Just $ DirTree_Symlink p $ Symlink_Internal s t
    in go x

instance Witherable DirTreeMaybe

-- | Map a function that could produce an empty result over a 'DirTree'
withDirTreeMaybe
  :: (DirTreeMaybe a -> DirTreeMaybe b)
  -> DirTree a
  -> Maybe (DirTree b)
withDirTreeMaybe f = unDirTreeMaybe . f . DirTreeMaybe . Just

-- | Map a function that could produce an empty result in the given functor
withDirTreeMaybeF
  :: Functor f
  => (DirTreeMaybe a -> f (DirTreeMaybe b))
  -> DirTree a
  -> f (Maybe (DirTree b))
withDirTreeMaybeF f = fmap unDirTreeMaybe . f . DirTreeMaybe . Just

-- | 'wither' for 'DirTree'. This represents the case of no paths left after
-- filtering with 'Nothing' (something that the 'DirTree' type can't represent on
-- its own).  NB: Filtering does not remove directories, only files. The
-- directory structure remains intact. To remove empty directories, see
-- 'pruneDirTree'.
witherDirTree
  :: Applicative f
  => (a -> f (Maybe b))
  -> DirTree a
  -> f (Maybe (DirTree b))
witherDirTree = withDirTreeMaybeF . wither

-- | 'filterA' for 'DirTree'. See 'witherDirTree'.
filterADirTree
  :: Applicative f
  => (a -> f Bool)
  -> DirTree a
  -> f (Maybe (DirTree a))
filterADirTree = withDirTreeMaybeF . filterA

-- | 'mapMaybe' for 'DirTree'. See 'witherDirTree'.
mapMaybeDirTree :: (a -> Maybe b) -> DirTree a -> Maybe (DirTree b)
mapMaybeDirTree = withDirTreeMaybe . mapMaybe

-- | 'catMaybes' for 'DirTree'. See 'witherDirTree'.
catMaybesDirTree :: DirTree (Maybe a) -> Maybe (DirTree a)
catMaybesDirTree = withDirTreeMaybe catMaybes

-- | 'Data.Witherable.filter' for 'DirTree'. See 'witherDirTree'.
filterDirTree :: (a -> Bool) -> DirTree a -> Maybe (DirTree a)
filterDirTree = withDirTreeMaybe . Data.Witherable.filter

-- | Remove empty directories from the 'DirTree'
pruneDirTree :: DirTree a -> Maybe (DirTree a)
pruneDirTree = \case
  DirTree_Dir a xs ->
    sub (DirTree_Dir a) xs
  DirTree_File a f ->
    Just $ DirTree_File a f
  DirTree_Symlink a (Symlink_External s xs) ->
    sub (DirTree_Symlink a . Symlink_External s) xs
  DirTree_Symlink a (Symlink_Internal s t) ->
    Just $ DirTree_Symlink a (Symlink_Internal s t)
  where
    sub c xs = case mapMaybe pruneDirTree xs of
      [] -> Nothing
      ys -> Just $ c ys

-- * Display
-- | Produces a tree drawing (using only text) of a 'DirTree' hierarchy.
drawDirTree :: DirTree a -> Text
drawDirTree = T.pack . drawDirTreeWith const

-- | Apply a rendering function to each file when drawing the directory hierarchy
drawDirTreeWith :: (String -> a -> String) -> DirTree a -> String
drawDirTreeWith f = DataTree.drawTree . pathToTree
  where
    pathToTree = \case
      DirTree_File p a ->
        DataTree.Node (f (takeFileName p) a) []
      DirTree_Dir p ps ->
        DataTree.Node (takeFileName p) $ pathToTree <$> ps
      DirTree_Symlink p (Symlink_Internal s _) ->
        DataTree.Node (showSym p s) []
      DirTree_Symlink p (Symlink_External s xs) ->
        DataTree.Node (showSym p s) $ pathToTree <$> xs
    showSym p s = takeFileName p <> " -> " <> s

-- | Print the 'DirTree' as a tree. For example:
--
-- @
--
-- System
-- |
-- `- Directory
--    |
--    `- Contents.hs
--
-- @
printDirTree :: DirTree a -> IO ()
printDirTree = putStrLn . T.unpack . drawDirTree

-- * Utilities

-- | Make one filepath relative to another
mkRelative :: FilePath -> FilePath -> FilePath
mkRelative root fp = case stripPrefix (dropTrailingPathSeparator root) fp of
  Nothing -> []
  Just r ->
    -- Remove the leading slash - we know it'll be there because
    -- we removed the trailing slash (if it was there) from the root
    drop 1 r

-- | Get the first 'Alternative'
alternative :: Alternative f => [f a] -> f a
alternative = getAlt . mconcat . fmap Alt

-- | Extract the 'FilePath' from a 'DirTree' node
filePath :: DirTree a -> FilePath
filePath = \case
  DirTree_Dir f _ -> f
  DirTree_File f _ -> f
  DirTree_Symlink f _ -> f
