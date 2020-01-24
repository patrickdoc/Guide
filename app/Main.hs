{-# LANGUAGE NamedFieldPuns     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE OverloadedStrings  #-}

module Main where

import           Control.Lens
import           Control.Monad
import           Data.Aeson                 as A
import           Data.Aeson.Lens
import           Development.Shake
import           Development.Shake.Classes
import           Development.Shake.Forward
import           Development.Shake.FilePath
import           GHC.Generics               (Generic)
import           Slick
import           Slick.Pandoc
import           Text.Pandoc.Options
import           Text.Pandoc.Writers

import qualified Data.HashMap.Lazy as HML
import qualified Data.Text                  as T

import           Port67                     (port67Reader, port67Writer)

---Config-----------------------------------------------------------------------

siteMeta :: SiteMeta
siteMeta =
    SiteMeta { siteAuthor = "Patrick Dougherty"
             , baseUrl = "https://port67.org"
             , siteTitle = "Port67"
             }

outputFolder :: FilePath
outputFolder = "docs"

inputFolder :: FilePath
inputFolder = "site"

--Data models-------------------------------------------------------------------

withSiteMeta :: Value -> Value
withSiteMeta (Object obj) = Object $ HML.union obj siteMetaObj
  where
    Object siteMetaObj = toJSON siteMeta
withSiteMeta _ = error "only add site meta to objects"

mergeVals :: Value -> Value -> Value
mergeVals (Object x) (Object y) = Object $ HML.union x y

data SiteMeta =
    SiteMeta { siteAuthor    :: String
             , baseUrl       :: String
             , siteTitle     :: String
             }
    deriving (Generic, Eq, Ord, Show, ToJSON)

-- | Custom Markdown to HTML converter
mdToPort67' :: T.Text -> Action Post
mdToPort67' =
  mdToHTMLWithRdrWrtr' port67Reader port67Writer

-- | Data for a blog post
data Post =
  Post
    { title    :: String
    , content  :: String
    , subFiles :: Maybe [String]
    } deriving (Generic, Eq, Ord, Show, FromJSON, ToJSON, Binary)

data EnrichedPost =
  EnrichedPost
    { post     :: Post
    , url      :: String
    , subPosts :: [EnrichedPost]
    } deriving (Generic, Show, FromJSON, ToJSON, Binary)

getSubFiles :: Post -> [String]
getSubFiles p = case (subFiles p) of
    Nothing -> []
    Just x -> x

-- | Build root index
buildIndex :: FilePath -> Action EnrichedPost
buildIndex root = do
  liftIO . putStrLn $ "Rebuilding post: " <> root <> "/index.md"

  -- load post and metadata
  postContent <- readFile' (inputFolder </> root </> "index.md")
  postData <- mdToPort67' . T.pack $ postContent

  -- Build "subFiles"
  posts' <- forP (map ((inputFolder </> root) </>) (getSubFiles postData)) buildEnrichedPost

  -- Same level posts
  -- pPaths <- getDirectoryFiles "." [inputFolder </> root </> "*.md"]
  -- let ps = filter (not . (?==) "**/index.md") pPaths
  -- posts' <- forP ps buildPost

  -- Lower indicies
  -- iPaths <- getDirectoryFiles (inputFolder </> root) ["*/index.md"]
  -- subIndicies <- mapM (\x -> buildIndices (root </> takeDirectory1 x)) iPaths

  -- Create this index
  indexT <- compileTemplate' "site/templates/index.html"
  let enrichedPost = EnrichedPost { post = postData, url = root </> "index.md", subPosts = posts' }
      indexHTML = T.unpack $ substitute indexT (withSiteMeta (toJSON enrichedPost))
  writeFile' (outputFolder </> root </> "index.html") indexHTML
  return enrichedPost

-- | Load a post, process metadata, write it to output, then return the post object
-- Detects changes to either post content or template
buildEnrichedPost :: FilePath -> Action EnrichedPost
buildEnrichedPost srcPath = cacheAction ("build" :: T.Text, srcPath) $ do
  liftIO . putStrLn $ "Rebuilding post: " <> srcPath

  -- load post and metadata
  postContent <- readFile' srcPath
  postData <- mdToPort67' . T.pack $ postContent

  let postUrl = dropDirectory1 $ srcPath -<.> "html"
      enrichedPost = EnrichedPost { post = postData, url = postUrl, subPosts = [] }
  -- Add additional metadata we've been able to compute
  let fullPostData = withSiteMeta $ toJSON postData
  template <- compileTemplate' "site/templates/post.html"
  writeFile' (outputFolder </> postUrl) . T.unpack $ substitute template fullPostData
  return enrichedPost

-- | Find and build all posts
buildPosts :: Action [Post]
buildPosts = do
  pPaths <- getDirectoryFiles "." ["site/posts//*.md"]
  forP (filter (not . (?==) "**/index.md") pPaths) buildPost

-- | Load a post, process metadata, write it to output, then return the post object
-- Detects changes to either post content or template
buildPost :: FilePath -> Action Post
buildPost srcPath = cacheAction ("build" :: T.Text, srcPath) $ do
  liftIO . putStrLn $ "Rebuilding post: " <> srcPath
  postContent <- readFile' srcPath
  -- load post content and metadata as JSON blob
  postData <- mdToPort67 . T.pack $ postContent
  let postUrl = T.pack . dropDirectory1 $ srcPath -<.> "html"
      withPostUrl = _Object . at "url" ?~ String postUrl
  -- Add additional metadata we've been able to compute
  let fullPostData = withSiteMeta . withPostUrl $ postData
  template <- compileTemplate' "site/templates/post.html"
  writeFile' (outputFolder </> T.unpack postUrl) . T.unpack $ substitute template fullPostData
  convert fullPostData

-- | Copy all static files from the listed folders to their destination
copyStaticFiles :: Action ()
copyStaticFiles = do
    filepaths <- getDirectoryFiles "./site/" ["images//*", "css//*", "js//*"]
    void $ forP filepaths $ \filepath ->
        copyFileChanged ("site" </> filepath) (outputFolder </> filepath)

-- | Specific build rules for the Shake system
--   defines workflow to build the website
buildRules :: Action ()
buildRules = do
  indices <- buildIndex "posts"
  --buildPosts
  copyStaticFiles

-- | Opening hooks for custom readers and writers
mdToHTMLWithRdrWrtr
    :: (ReaderOptions -> PandocReader T.Text)
    -> (WriterOptions -> PandocWriter)
    -> T.Text
    -> Action Value
mdToHTMLWithRdrWrtr rdr wrtr txt =
  loadUsing
    (rdr defaultMarkdownOptions)
    (wrtr defaultHtml5Options)
    txt

-- | Opening hooks for custom readers and writers
mdToHTMLWithRdrWrtr'
    :: (FromJSON a)
    => (ReaderOptions -> PandocReader T.Text)
    -> (WriterOptions -> PandocWriter)
    -> T.Text
    -> Action a
mdToHTMLWithRdrWrtr' rdr wrtr txt =
  loadUsing'
    (rdr defaultMarkdownOptions)
    (wrtr defaultHtml5Options)
    txt

-- | Custom Markdown to HTML converter
mdToPort67 :: T.Text -> Action Value
mdToPort67 =
  mdToHTMLWithRdrWrtr port67Reader port67Writer

main :: IO ()
main = do
  let shOpts = shakeOptions { shakeVerbosity = Chatty, shakeLintInside = ["site/"] }
  shakeArgsForward shOpts buildRules
