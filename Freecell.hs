{-# LANGUAGE DoRec, OverloadedStrings, TupleSections #-}
module Freecell (freecell) where

import Geometry
import FRP.Sodium
import Control.Applicative
import Control.Monad
import Data.Traversable (sequenceA)
import Data.List
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe
import Data.Monoid
import Platform
import System.Random
import System.FilePath
import Data.Array.IArray as A
import Data.Array.ST
import Data.Text (Text)

data Suit  = Spades | Clubs | Diamonds | Hearts
             deriving (Eq, Ord, Show, Enum, Bounded)
data Value = Ace | Two | Three | Four | Five | Six | Seven | Eight | Nine | Ten | Jack | Queen | King
             deriving (Eq, Ord, Show, Enum, Bounded)
data Card  = Card Value Suit
             deriving (Eq, Ord, Show)

instance Enum Card where
    fromEnum (Card v s) = fromEnum v + fromEnum s * 13
    toEnum i = Card (toEnum v) (toEnum s)
      where
        (s, v) = divMod i 13

instance Bounded Card where
    minBound = Card minBound minBound
    maxBound = Card maxBound maxBound 

cardFn :: Card -> FilePath
cardFn (Card v s) = suitName s ++ valueName v ++ ".png"
  where
    suitName Spades = "s"
    suitName Clubs = "c"
    suitName Diamonds = "d"
    suitName Hearts = "h"
    valueName Ace = "1"
    valueName Two = "2"
    valueName Three = "3"
    valueName Four = "4"
    valueName Five = "5"
    valueName Six = "6"
    valueName Seven = "7"
    valueName Eight = "8"
    valueName Nine = "9"
    valueName Ten = "10"
    valueName Jack = "j"
    valueName Queen = "q"
    valueName King = "k"

freecell :: Platform p => FilePath -> IO (Behavior Coord -> Game p)
freecell resPath = do
    cards <- forM [minBound..maxBound] $ \card -> do
        i <- image resPath (cardFn card)
        return (card, i)
    let cardsM = M.fromList cards
        draw card = fromJust $ M.lookup card cardsM
    emptySpace <- image resPath "empty-space.png"
    return $ game draw emptySpace

noOfStacks :: Int
noOfStacks = 8

noOfCells :: Int
noOfCells = 4

cardSize :: Coord -> Vector
cardSize aspect = (90 * aspect, 135 * aspect)

maxCardsPerStack = 14

overlapY :: Coord -> Coord
overlapY aspect = (stackTop aspect - ((-1000) + topMargin + cardHeight)) / (maxCardsPerStack - 1)
  where
    (_, cardHeight) = cardSize aspect

data Location = Stack Int | Cell Int | Grave deriving (Eq, Show)

data Bunch = Bunch {
        buInitOrig     :: Point,
        buInitMousePos :: Point,
        buCards        :: [Card],
        buOrigin       :: Location
    }
    deriving Show

data Destination = Destination {
        deLocation :: Location,
        deDropZone :: Rect,
        deMayDrop  :: [Card] -> Bool
    }

validSequence :: [Card] -> Bool
validSequence xs = and $ zipWith follows xs (drop 1 xs)

follows :: Card -> Card -> Bool
follows one@(Card v1 _) two@(Card v2 _) = isRed one /= isRed two && (v1 /= Ace && pred v1 == v2)
  where
    isRed :: Card -> Bool
    isRed (Card _ suit) = suit == Hearts || suit == Diamonds

xExtent :: Coord -> Coord
xExtent aspect = 1000*aspect - leftMargin aspect - cardWidth
  where
    (cardWidth, _) = cardSize aspect

cardSpacing :: Coord -> Coord
cardSpacing aspect = 2*xExtent aspect / fromIntegral (noOfStacks-1)
  where
    (cardWidth, _) = cardSize aspect

cardSpacingNarrow :: Coord -> Coord
cardSpacingNarrow aspect = cardSpacing aspect * 0.9

topMargin :: Coord
topMargin = 50

leftMargin :: Coord -> Coord
leftMargin aspect = topMargin * aspect

topRow :: Coord -> Coord
topRow aspect = 1000 - topMargin - cardHeight
  where
    (cardWidth, cardHeight) = cardSize aspect

stackTop :: Coord -> Coord
stackTop aspect = topRow aspect - cardHeight * 2.5
  where (_, cardHeight) = cardSize aspect

-- | The vertical stacks of cards, where cards can only be added if they're
-- descending numbers and alternating red-black.
stack :: Platform p =>
         Behavior Coord
      -> (Card -> Drawable p)
      -> Event (MouseEvent p) -> [Card] -> Location -> Behavior Int -> Event [Card]
      -> Reactive (Behavior [Sprite p], Behavior Destination, Event Bunch)
stack aspect draw eMouse initCards loc@(Stack ix) freeSpaces eDrop = do
    let orig aspect =
            let (cardWidth, cardHeight) = cardSize aspect
            in  (
                    (-xExtent aspect) + fromIntegral ix * cardSpacing aspect,
                    stackTop aspect
                )
        positions aspect = iterate (\(x, y) -> (x, y-overlapY aspect)) (orig aspect)
    rec
        cards <- hold initCards (eRemoveCards `merge` eAddCards)
        let eAddCards = snapshotWith (\newCards cards -> cards ++ newCards) eDrop cards
            eMouseSelection = filterJust $ snapshotWith (\mev (cards, aspect) ->
                    let (cardWidth, cardHeight) = cardSize aspect
                        (origX, origY) = orig aspect
                    in  case mev of
                        MouseDown _ pt@(x, y) | x >= origX - cardWidth && x <= origX + cardWidth ->
                            let n = length cards
                                bottomY = (origY - cardHeight) - overlapY aspect * fromIntegral (n-1) 
                                ix = (length cards - 1) `min` floor (((origY + cardHeight) - y) / overlapY aspect)
                                (left, taken) = splitAt ix cards
                            in  if ix >= 0 && y >= bottomY
                                    then Just (left, Bunch (positions aspect !! ix) pt taken loc)
                                    else Nothing
                        _ -> Nothing
                ) eMouse (liftA2 (,) cards aspect)
            eRemoveCards = fst <$> eMouseSelection   -- Cards left over when we drag
            eDrag        = snd <$> eMouseSelection   -- Cards removed when we drag
    let sprites = (\cards aspect ->
                        zipWith (\pos card -> draw card (pos, cardSize aspect)) (positions aspect) cards
                  ) <$> cards <*> aspect
        dest = (\cards freeSpaces aspect -> Destination {
                    deLocation = loc,
                    deDropZone = (orig aspect `minus` (0, fromIntegral (length cards) * overlapY aspect), cardSize aspect),
                    deMayDrop = \newCards ->
                        validSequence newCards &&
                        -- You get one card for free, but there must be free cells for any
                        -- more than that.
                        (length newCards - 1) <= freeSpaces &&
                        case cards of
                            [] -> True
                            _  -> last cards `follows` head newCards
                }
            ) <$> cards <*> freeSpaces <*> aspect
    return (sprites, dest, eDrag)

-- | The "free cells" where cards can be temporarily put.
cell :: Platform p =>
        Behavior Float
     -> (Card -> Drawable p)
     -> Drawable p
     -> Event (MouseEvent p) -> Location -> Event [Card]
     -> Reactive (Behavior [Sprite p], Behavior Destination, Event Bunch, Behavior Int)
cell aspect draw emptySpace eMouse loc@(Cell ix) eDrop = do
    let orig aspect =
            let narrow = cardSpacingNarrow aspect
                (cardWidth, _) = cardSize aspect
            in  ((-xExtent aspect) + fromIntegral ix * narrow, topRow aspect)
        rect aspect = (orig aspect, cardSize aspect)
    rec
        mCard <- hold Nothing $ eRemove `merge` (Just . head <$> eDrop)
        let eMouseSelection = filterJust $ snapshotWith (\mev (mCard, aspect) ->
                    case (mev, mCard) of
                        (MouseDown _ pt, Just card) | pt `inside` rect aspect ->
                            Just (Nothing, Bunch (fst $ rect aspect) pt [card] loc)
                        _ -> Nothing
                ) eMouse (liftA2 (,) mCard aspect)
            eRemove = fst <$> eMouseSelection
            eDrag = snd <$> eMouseSelection
    let sprites = (\mCard aspect -> [case mCard of
                                       Just card -> draw card (orig aspect, cardSize aspect)
                                       Nothing   -> emptySpace (orig aspect, cardSize aspect)]
                  ) <$> mCard <*> aspect
        dest = (\mCard aspect -> Destination {
                deLocation = loc,
                deDropZone = rect aspect,
                deMayDrop = \newCards -> length newCards == 1 && isNothing mCard
            }) <$> mCard <*> aspect
        emptySpaces = (\c -> if isNothing c then 1 else 0) <$> mCard
    return (sprites, dest, eDrag, emptySpaces)

-- | The place where the cards end up at the top right, aces first.
grave :: Platform p =>
         Behavior Float
      -> (Card -> Drawable p)
      -> Drawable p
      -> Event (MouseEvent p) -> Event [Card]
      -> Reactive (Behavior [Sprite p], Behavior Destination, Event Bunch)
grave aspect draw emptySpace eMouse eDrop = do
    let xOf aspect ix =    let (cardWidth, _) = cardSize aspect
                           in  xExtent aspect - cardSpacingNarrow aspect * fromIntegral (3-ix)
        positions aspect = map (\ix -> (xOf aspect ix, topRow aspect)) [0..3]
        areas aspect = zip (positions aspect) (repeat $ cardSize aspect)
        wholeRect aspect = let (cardWidth, cardHeight) = cardSize aspect
                           in  (
                                   ((xOf aspect 0 + xOf aspect 3) * 0.5, topRow aspect),
                                   ((cardSpacingNarrow aspect * 3 + cardWidth*2) * 0.5, cardHeight)
                               ) 
    rec
        let eDropModify = snapshotWith (\newCards slots ->
                    let newCard@(Card _ suit) = head newCards
                        ix = fromEnum suit
                    in  take ix slots ++ [Just newCard] ++ drop (ix+1) slots 
                ) eDrop slots
        slots <- hold [Nothing, Nothing, Nothing, Nothing] (eDropModify `merge` eRemove)
        let eMouseSelection = filterJust $ snapshotWith (\mev (slots, aspect) ->
                    case mev of
                        MouseDown _ pt ->
                            let isIn = map (pt `inside`) (areas aspect)
                            in  case trueIxOf isIn of
                                    Just ix ->
                                        case slots !! ix of
                                            Just card@(Card value suit) ->
                                                let prevCard = if value == Ace then Nothing
                                                                               else Just (Card (pred value) suit)
                                                    slots' = take ix slots ++ [prevCard] ++ drop (ix+1) slots
                                                in  Just (slots', Bunch (positions aspect !! ix) pt [card] Grave)
                                            Nothing -> Nothing
                                    Nothing -> Nothing
                        _ -> Nothing
                ) eMouse (liftA2 (,) slots aspect)
            eRemove = fst <$> eMouseSelection
            eDrag = snd <$> eMouseSelection
    let sprites = (
            \aspect slots ->
                zipWith (\pos mSlot ->
                         maybe (emptySpace (pos, cardSize aspect)) (\card -> draw card (pos, cardSize aspect)) mSlot)
                    (positions aspect) slots
            ) <$> aspect <*> slots
        dest = (\slots aspect -> Destination {
                deLocation = Grave,
                deDropZone = wholeRect aspect,
                deMayDrop = \newCards -> case newCards of
                    [card@(Card value suit)] ->
                        let ix = fromEnum suit
                        in  case slots !! ix of
                                Just (Card topValue _) -> value == succ topValue
                                Nothing                -> value == Ace 
                    _                    -> False
            }) <$> slots <*> aspect
    return (sprites, dest, eDrag)
  where
    -- Index of first true item in the list
    trueIxOf items = doit items 0
      where
        doit [] _ = Nothing
        doit (x:xs) ix = if x then Just ix
                              else doit xs (ix+1)

-- | Draw the cards while they're being dragged.
dragger :: Platform p =>
           Behavior Coord
        -> (Card -> Drawable p)
        -> Event (MouseEvent p) -> Event Bunch -> Reactive (Behavior [Sprite p], Event (Point, Bunch))
dragger aspect draw eMouse eStartDrag = do
    dragPos <- hold (0,0) $ flip fmap eMouse $ \mev ->
        case mev of
            MouseUp   _ pt -> pt
            MouseMove _ pt -> pt
            MouseDown _ pt -> pt
    rec
        dragging <- hold Nothing $ (const Nothing <$> eDrop) `merge` (Just <$> eStartDrag)
        let eDrop = filterJust $ snapshotWith (\mev mDragging ->
                    case (mev, mDragging) of
                        -- If the mouse is released, and we are dragging...
                        (MouseUp _ pt, Just dragging) -> Just (cardPos pt dragging, dragging)
                        _                             -> Nothing
                ) eMouse dragging
    let sprites = drawDraggedCards <$> dragPos <*> dragging <*> aspect
          where
            drawDraggedCards pt (Just bunch) aspect =
                let cpos = cardPos pt bunch
                    positions = iterate (\(x, y) -> (x, y-overlapY aspect)) cpos
                in  zipWith (\card pos -> draw card (pos, cardSize aspect)) (buCards bunch) positions
            drawDraggedCards _ Nothing _ = []
    return (sprites, eDrop)
  where
    cardPos pt bunch = (pt `minus` buInitMousePos bunch) `plus` buInitOrig bunch

-- | Determine where dropped cards are routed to.
dropper :: Event (Point, Bunch) -> Behavior [Destination] -> Event (Location, [Card])
dropper eDrop dests =
    snapshotWith (\(pt, bunch) dests ->
                -- If none of the destinations will accept the dropped cards, then send them
                -- back where they originated from.
                let findDest [] = (buOrigin bunch, buCards bunch)
                    findDest (dest:rem) =
                        if pt `inside` deDropZone dest && deMayDrop dest (buCards bunch)
                            then (deLocation dest, buCards bunch)
                            else findDest rem
                in  findDest dests
            ) eDrop dests

distributeTo :: Event (Location, [Card]) -> [Location] -> [Event [Card]]
distributeTo eWhere locations = flip map locations $ \thisLoc ->
    filterJust $ (\(loc, cards) ->
            if loc == thisLoc
                then Just cards
                else Nothing
        ) <$> eWhere

game :: Platform p =>
        (Card -> Drawable p)
     -> Drawable p
     -> Behavior Coord  -- ^ Aspect ratio
     -> Event (MouseEvent p)
     -> Behaviour Double
     -> StdGen
     -> Reactive (
            Behaviour (Sprite p),
            Behavior (Text, [Sound p]),
            Event (Sound p)
        )
game draw emptySpace aspect eMouse time rng = do
    let stackCards =
            let (cards, _) = shuffle rng [minBound..maxBound]
            in  toStacks noOfStacks cards
        stLocs = map Stack [0..noOfStacks-1]
        ceLocs = map Cell [0..noOfCells-1]
    rec
        let eWhere = dropper eDrop (sequenceA (stDests ++ ceDests ++ [grDest]))
            stDrops = eWhere `distributeTo` stLocs
            ceDrops = eWhere `distributeTo` ceLocs
            grDrops = eWhere `distributeTo` [Grave]
        (stSprites, stDests, stDrags) <- unzip3 <$> forM (zip3 stLocs stackCards stDrops) (\(loc, cards, drop) ->
            stack aspect draw eMouse cards loc emptySpaces drop)
        (ceSprites, ceDests, ceDrags, ceEmptySpaces) <- unzip4 <$> forM (zip ceLocs ceDrops) (\(loc, drop) ->
            cell aspect draw emptySpace eMouse loc drop)
        (grSprites, grDest, grDrag) <- grave aspect draw emptySpace eMouse (head grDrops)
        -- The total number of empty spaces available in cells - 0 to 4. We need to
        -- know this when we drop a stack of cards, because (the rules of the game say)
        -- this is equivalent to temporarily putting all but one of them in cells.
        let emptySpaces = foldr1 (\x y -> (+) <$> x <*> y) ceEmptySpaces
        (drSprites, eDrop) <- dragger aspect draw eMouse (foldr1 merge (stDrags ++ ceDrags ++ [grDrag]))
    return (
        mconcat . concat <$> sequenceA (stSprites ++ ceSprites ++ [grSprites] ++ [drSprites]),
        pure ("", []),
        never
      )

shuffle :: StdGen -> [Card] -> ([Card], StdGen)
shuffle rng cards =
    let n = length cards
        (rng', ixes) = mapAccumL (\rng () ->
                let (ix, rng') = randomR (0, n-1) rng
                in  (rng', ix)) rng (replicate n ())
        ary = runSTArray $ do
            ary <- newListArray (0, n-1) cards
            forM_ (zip [0..n-1] ixes) $ \(ix1, ix2) -> do
                when (ix1 /= ix2) $ do
                    one <- readArray ary ix1
                    two <- readArray ary ix2
                    writeArray ary ix1 two
                    writeArray ary ix2 one
            return ary
    in  (A.elems ary, rng')

toStacks :: Int -> [Card] -> [[Card]]
toStacks noOfStacks cards = foldl (\stacks layer ->
        zipWith (++) (map (:[]) layer ++ repeat []) stacks
    ) (replicate noOfStacks []) (layerize cards)
  where
    layerize :: [Card] -> [[Card]]
    layerize cards = case splitAt noOfStacks cards of
        ([], _) -> []
        (layer, rem) -> layer : layerize rem

