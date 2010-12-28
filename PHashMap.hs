module PHashMap (PHashMap,
                 empty,
                 insert,
                 insertWith,
                 alter,
                 update,
                 PHashMap.delete,
                 PHashMap.lookup,
                 member,
                 keys,
                 elems,
                 toList,
                 fromList) where

import Data.Bits
import Data.Int
import Data.List hiding (insert, lookup)
import Data.Array as A
import Prelude as P
import Control.Monad

-- Some constants
shiftStep :: Int
shiftStep = 5

chunk :: Int32
chunk = 2^shiftStep

mask :: Int32
mask = pred chunk


data (Eq k) => PHashMap k v = PHM {
                                  hashFn :: k -> Int32,
                                  root :: Node k v
                              }

instance (Eq k, Show k, Show v) => Show (PHashMap k v) where
    show (PHM _hashFn root) = show root

data (Eq k) => Node k v = EmptyNode |
                          LeafNode {
                              hash :: Int32,
                              key :: k,
                              value :: v
                          } |
                          HashCollisionNode {
                              hash :: Int32,
                              pairs :: [(k, v)]
                          } |
                          BitmapIndexedNode {
                              bitmap :: Int32,
                              subNodes :: Array Int32 (Node k v)
                          } |
                          ArrayNode {
                              numChildren :: Int,
                              subNodes :: Array Int32 (Node k v)
                          }

instance (Eq k, Show k, Show v) => Show (Node k v) where
    show EmptyNode = ""
    show (LeafNode _hash key value) = show (key, value)
    show (HashCollisionNode _hash pairs) = "h" ++ show pairs
    show (BitmapIndexedNode bitmap subNodes) = "b" ++ show bitmap ++ (show $ A.elems subNodes)
    show (ArrayNode numChildren subNodes) = "a" ++ show numChildren ++ (show $ A.elems subNodes)


-- (empty hashFn) is the empty PHashMap, with hashFn being the key hash function
empty :: (Eq k) => (k -> Int32) -> PHashMap k v

empty hashFn = PHM hashFn EmptyNode


-- (insertWith accumFn key value hashMap) is hashMap with (key, value) inserted using accumulation
-- function accumFn.  If value v1 is inserted with the same key as an existing value v2, the new
-- value will be v1 `accumFn` v2
insertWith :: (Eq k) => (v -> v -> v) -> k -> v -> PHashMap k v -> PHashMap k v

insertWith accumFn key value hashMap =
    let fn :: (v -> v -> v) -> v -> Maybe v -> Maybe v
        fn accumFn x' Nothing = Just x'
        fn accumFn x' (Just x) = Just $ accumFn x' x
        in alter (fn accumFn value) key hashMap


-- A helper function for insertNodeWith
combineNodes :: (Eq k) => Int -> Node k v -> Node k v -> Node k v

combineNodes shift node node' =
    let subHash = hashFragment shift (nodeHash node)
        subHash2 = hashFragment shift (nodeHash node')
        (nodeA, nodeB) = if (subHash < subHash2)
                            then (node, node')
                            else (node', node)
        bitmap' = ((toBitmap subHash) .|. (toBitmap subHash2))
        subNodes' = if subHash == subHash2
                       then listArray (0, 0) [combineNodes (shift+shiftStep) node node']
                       else listArray (0, 1) [nodeA, nodeB]
        in BitmapIndexedNode bitmap' subNodes'

    where
    nodeHash (LeafNode hash key value) = hash
    nodeHash (HashCollisionNode hash pairs) = hash


-- (insert key value hashMap) is hashMap with (key, value) inserted, replacing any previous
-- value with the given key.
insert :: (Eq k) => k -> v -> PHashMap k v -> PHashMap k v

insert = insertWith const


-- Helper data type for alterNode
data Change = Removed | Modified | Nil | Added deriving Eq


-- (alter updateFn key hashMap) is hashMap with the value at key updated using updateFn.
-- If updateFn returns Nothing, then the key-value pair is removed
alter :: (Eq k) => (Maybe v -> Maybe v) -> k -> PHashMap k v -> PHashMap k v

alter updateFn key (PHM hashFn root) =
    PHM hashFn $ alterNode 0 updateFn (hashFn key) key root


alterNode :: (Eq k) => Int -> (Maybe v -> Maybe v) -> Int32 -> k -> Node k v -> Node k v

alterNode _shift updateFn hash key EmptyNode =
    maybe EmptyNode
          (LeafNode hash key)
          (updateFn Nothing)

alterNode shift updateFn hash' key' node@(LeafNode hash key value) =
    if key' == key
       then maybe EmptyNode
                  (LeafNode hash key)
                  (updateFn (Just value))
       else let node' = alterNode shift updateFn hash' key' EmptyNode
                in if nodeIsEmpty node'
                      then node
                      else combineNodes shift node node'

alterNode _shift updateFn _hash' key (HashCollisionNode hash pairs) =
    let pairs' = updateList updateFn key pairs
        in case pairs' of
                [(key, value)] -> LeafNode hash key value
                otherwise      -> HashCollisionNode hash pairs'
    where updateList updateFn key [] = []
          updateList updateFn key' ((key, value):pairs) | key' == key =
              maybe pairs
                    (\value' -> (key, value'):pairs)
                    (updateFn (Just value))
          updateList updateFn key (p:pairs) =
              p : updateList updateFn key pairs

alterNode shift updateFn hash key bmnode@(BitmapIndexedNode bitmap subNodes) =
    let subHash = hashFragment shift hash
        ix = fromBitmap bitmap subHash
        bit = toBitmap subHash
        exists = (bitmap .&. bit) /= 0
        child = if exists then subNodes ! fromIntegral ix else EmptyNode
        child' = alterNode (shift+shiftStep) updateFn hash key child
        removed = exists && nodeIsEmpty child'
        added = not exists && not (nodeIsEmpty child')
        change = if exists
                    then if nodeIsEmpty child'
                            then Removed
                            else Modified
                 else if nodeIsEmpty child'
                    then Nil
                    else Added
        bound = snd $ bounds subNodes
        bound' = case change of
                      Removed  -> bound-1
                      Modified -> bound
                      Nil      -> bound
                      Added    -> bound+1
        (left, right) = splitAt ix $ A.elems subNodes
        subNodes' = case change of
                         Removed  -> listArray (0, bound') $ left ++ (tail right)
                         Modified -> subNodes // [(fromIntegral ix, child')]
                         Nil      -> subNodes
                         Added    -> listArray (0, bound') $ left ++ (child':right)
        bitmap' = case change of
                       Removed  -> bitmap .&. (complement bit)
                       Modified -> bitmap
                       Nil      -> bitmap
                       Added    -> bitmap .|. bit
        in if bitmap' == 0
              then -- Remove an empty BitmapIndexedNode
                   -- Note: it's possible to have a single-element BitmapIndexedNode
                   -- if there are two keys with the same subHash in the trie.
                   EmptyNode
           else if bound' == 0 && isLeafNode (subNodes' ! 0)
              then -- Pack a BitmapIndexedNode into a LeafNode
                   subNodes' ! 0
           else if change == Added && bound' > 15
              then -- Expand a BitmapIndexedNode into an ArrayNode
                   expandBitmapNode shift subHash child' bitmap subNodes
              else BitmapIndexedNode bitmap' subNodes'
    where
    isLeafNode (LeafNode _ _ _) = True
    isLeafNode _ = False

    expandBitmapNode :: (Eq k) =>
        Int -> Int32 -> Node k v -> Int32 -> Array Int32 (Node k v) -> Node k v
    expandBitmapNode shift subHash node' bitmap subNodes =
        let assocs = zip (bitmapToIndices bitmap) (A.elems subNodes)
            assocs' = (subHash, node'):assocs
            blank = listArray (0, 31) $ replicate 32 EmptyNode
            numChildren = (bitCount32 bitmap) + 1
            in ArrayNode numChildren $ blank // assocs'
            -- TODO: an array copy could be avoided here

alterNode shift updateFn hash key node@(ArrayNode numChildren subNodes) =
    let subHash = hashFragment shift hash
        child = subNodes ! subHash
        child' = alterNode (shift+shiftStep) updateFn hash key child
        removed = nodeIsEmpty child' && not (nodeIsEmpty child)
        numChildren' = if removed
                          then numChildren - 1
                          else numChildren
        in if numChildren' < fromIntegral chunk `div` 4
              -- Pack an ArrayNode into a HashCollisionNode when usage drops below 25%
              then packArrayNode subHash numChildren subNodes
              else ArrayNode numChildren' $ subNodes // [(subHash, child')]
    where
    packArrayNode :: (Eq k) => Int32 -> Int -> Array Int32 (Node k v) -> Node k v
    packArrayNode subHashToRemove numChildren subNodes =
        let elems' = map (\i -> if i == subHashToRemove
                                   then EmptyNode
                                   else subNodes ! i)
                         [0..pred chunk]
            subNodes' = listArray (0, fromIntegral (numChildren-2)) $ filter (not.nodeIsEmpty) elems'
            listToBitmap = foldr (\on bm -> (bm `shiftL` 1) .|. (if on then 1 else 0)) 0
            bitmap = listToBitmap $ map (not.nodeIsEmpty) elems'
            in BitmapIndexedNode bitmap subNodes'


-- (update updateFn key hashMap) is hashMap with the value at key updated using updateFn.
-- If updateFn returns Nothing, then the key-value pair is removed
update :: (Eq k) => (v -> Maybe v) -> k -> PHashMap k v -> PHashMap k v

update updateFn = alter ((=<<) updateFn)


-- (delete updateFn key hashMap) is hashMap with the value at key removed
delete :: (Eq k) => k -> PHashMap k v -> PHashMap k v

delete = alter (const Nothing)


-- (adjust updateFn key hashMap) is hashMap with the value at key updated using updateFn.
adjust :: (Eq k) => (v -> v) -> k -> PHashMap k v -> PHashMap k v

adjust updateFn = update ((Just).updateFn)


-- (lookup key hashMap) is Just the value stored at the key, or Nothing if no such key exists
lookup :: (Eq k) => k -> PHashMap k v -> Maybe v

lookup key (PHM hashFn root) = lookupNode 0 (hashFn key) key root


lookupNode :: (Eq k) => Int -> Int32 -> k -> Node k v -> Maybe v

lookupNode _ _ _ EmptyNode = Nothing

lookupNode _ _ key' (LeafNode _ key value) =
    if key' == key then Just value
                        else Nothing

lookupNode _ _ key (HashCollisionNode _ pairs) =
    P.lookup key pairs

lookupNode shift hash key (BitmapIndexedNode bitmap subNodes) =
    let subHash = hashFragment shift hash
        ix = fromBitmap bitmap subHash
        exists = (bitmap .&. (toBitmap subHash)) /= 0
        in if exists
              then lookupNode (shift+shiftStep) hash key (subNodes!ix)
              else Nothing

lookupNode shift hash key (ArrayNode _numChildren subNodes) =
    let subHash = hashFragment shift hash
        in lookupNode (shift+shiftStep) hash key (subNodes!subHash)


member :: (Eq k) => k -> PHashMap k v -> Bool

member k hashMap = maybe False (const True) (PHashMap.lookup k hashMap)


-- (toList hashMap) is all the key-value pairs in hashMap as a list
toList :: (Eq k) => PHashMap k v -> [(k, v)]

toList (PHM _hashFn root) = toListNode root


toListNode :: (Eq k) => Node k v -> [(k, v)]

toListNode EmptyNode = []

toListNode (LeafNode _hash key value) = [(key, value)]

toListNode (HashCollisionNode _hash pairs) = pairs

toListNode (BitmapIndexedNode _bitmap subNodes) =
    concat $ map toListNode $ A.elems subNodes

toListNode (ArrayNode _numChildren subNodes) =
    concat $ map toListNode $ A.elems subNodes


-- (fromList hashFn list) is a PHashMap equivalent to list interpreted as a dictionary
fromList :: (Eq k) => (k -> Int32) -> [(k, v)] -> PHashMap k v

fromList hashFn = foldl' (\hm (key, value) -> insert key value hm)
                         (empty hashFn)
                  -- TODO: make this more efficient by using a transient array


-- (keys hashMap) is a list of all keys in hashMap
keys :: (Eq k) => PHashMap k v -> [k]

keys (PHM _hashFn root) = keysNode root


keysNode :: (Eq k) => Node k v -> [k]

keysNode EmptyNode = []

keysNode (LeafNode _hash key _value) = [key]

keysNode (HashCollisionNode _hash pairs) =
    map fst pairs

keysNode (BitmapIndexedNode _bitmap subNodes) =
    concat $ map keysNode $ A.elems subNodes

keysNode (ArrayNode _numChildren subNodes) =
    concat $ map keysNode $ A.elems subNodes


-- (elems hashMap) is a list of all values in hashMap
elems :: (Eq k) => PHashMap k v -> [v]

elems (PHM _hashFn root) = elemsNode root


elemsNode :: (Eq k) => Node k v -> [v]

elemsNode EmptyNode = []

elemsNode (LeafNode _hash _key value) = [value]

elemsNode (HashCollisionNode _hash pairs) =
    map snd pairs

elemsNode (BitmapIndexedNode _bitmap subNodes) =
    concat $ map elemsNode $ A.elems subNodes

elemsNode (ArrayNode _numChildren subNodes) =
    concat $ map elemsNode $ A.elems subNodes


-- Some miscellaneous helper functions

nodeIsEmpty :: Node k v -> Bool
nodeIsEmpty EmptyNode = True
nodeIsEmpty _ = False

hashFragment shift hash = (hash `shiftR` shift) .&. fromIntegral mask

-- Bit operations

-- Given a bitmap and a subhash, this function returns the index into the list
fromBitmap :: (Integral a, Bits a, Integral b, Num c) => a -> b -> c
fromBitmap bitmap subHash = fromIntegral $ bitCount32 $ bitmap .&. (pred (toBitmap subHash))

toBitmap :: (Bits t, Integral a) => a -> t
toBitmap subHash = 1 `shiftL` fromIntegral subHash

bitmapToIndices :: (Bits a, Num b) => a -> [b]
bitmapToIndices bitmap = loop 0 bitmap
    where loop _ 0  = []
          loop 32 _ = []
          loop ix bitmap | bitmap .&. 1 == 0 = loop (ix+1) (bitmap `shiftR` 1)
                         | otherwise         = ix:(loop (ix+1) (bitmap `shiftR` 1))

bitCount32 :: (Bits a, Integral b) => a -> b
bitCount32 x = bitCount8 ((x `shiftR` 24) .&. 0xff) +
               bitCount8 ((x `shiftR` 16) .&. 0xff) +
               bitCount8 ((x `shiftR` 8) .&. 0xff) +
               bitCount8 (x .&. 0xff)

bitCount8 :: (Bits a, Integral b) => a -> b
bitCount8 0 = 0
bitCount8 1 = 1
bitCount8 2 = 1
bitCount8 3 = 2
bitCount8 4 = 1
bitCount8 5 = 2
bitCount8 6 = 2
bitCount8 7 = 3
bitCount8 8 = 1
bitCount8 9 = 2
bitCount8 10 = 2
bitCount8 11 = 3
bitCount8 12 = 2
bitCount8 13 = 3
bitCount8 14 = 3
bitCount8 15 = 4
bitCount8 16 = 1
bitCount8 17 = 2
bitCount8 18 = 2
bitCount8 19 = 3
bitCount8 20 = 2
bitCount8 21 = 3
bitCount8 22 = 3
bitCount8 23 = 4
bitCount8 24 = 2
bitCount8 25 = 3
bitCount8 26 = 3
bitCount8 27 = 4
bitCount8 28 = 3
bitCount8 29 = 4
bitCount8 30 = 4
bitCount8 31 = 5
bitCount8 32 = 1
bitCount8 33 = 2
bitCount8 34 = 2
bitCount8 35 = 3
bitCount8 36 = 2
bitCount8 37 = 3
bitCount8 38 = 3
bitCount8 39 = 4
bitCount8 40 = 2
bitCount8 41 = 3
bitCount8 42 = 3
bitCount8 43 = 4
bitCount8 44 = 3
bitCount8 45 = 4
bitCount8 46 = 4
bitCount8 47 = 5
bitCount8 48 = 2
bitCount8 49 = 3
bitCount8 50 = 3
bitCount8 51 = 4
bitCount8 52 = 3
bitCount8 53 = 4
bitCount8 54 = 4
bitCount8 55 = 5
bitCount8 56 = 3
bitCount8 57 = 4
bitCount8 58 = 4
bitCount8 59 = 5
bitCount8 60 = 4
bitCount8 61 = 5
bitCount8 62 = 5
bitCount8 63 = 6
bitCount8 64 = 1
bitCount8 65 = 2
bitCount8 66 = 2
bitCount8 67 = 3
bitCount8 68 = 2
bitCount8 69 = 3
bitCount8 70 = 3
bitCount8 71 = 4
bitCount8 72 = 2
bitCount8 73 = 3
bitCount8 74 = 3
bitCount8 75 = 4
bitCount8 76 = 3
bitCount8 77 = 4
bitCount8 78 = 4
bitCount8 79 = 5
bitCount8 80 = 2
bitCount8 81 = 3
bitCount8 82 = 3
bitCount8 83 = 4
bitCount8 84 = 3
bitCount8 85 = 4
bitCount8 86 = 4
bitCount8 87 = 5
bitCount8 88 = 3
bitCount8 89 = 4
bitCount8 90 = 4
bitCount8 91 = 5
bitCount8 92 = 4
bitCount8 93 = 5
bitCount8 94 = 5
bitCount8 95 = 6
bitCount8 96 = 2
bitCount8 97 = 3
bitCount8 98 = 3
bitCount8 99 = 4
bitCount8 100 = 3
bitCount8 101 = 4
bitCount8 102 = 4
bitCount8 103 = 5
bitCount8 104 = 3
bitCount8 105 = 4
bitCount8 106 = 4
bitCount8 107 = 5
bitCount8 108 = 4
bitCount8 109 = 5
bitCount8 110 = 5
bitCount8 111 = 6
bitCount8 112 = 3
bitCount8 113 = 4
bitCount8 114 = 4
bitCount8 115 = 5
bitCount8 116 = 4
bitCount8 117 = 5
bitCount8 118 = 5
bitCount8 119 = 6
bitCount8 120 = 4
bitCount8 121 = 5
bitCount8 122 = 5
bitCount8 123 = 6
bitCount8 124 = 5
bitCount8 125 = 6
bitCount8 126 = 6
bitCount8 127 = 7
bitCount8 128 = 1
bitCount8 129 = 2
bitCount8 130 = 2
bitCount8 131 = 3
bitCount8 132 = 2
bitCount8 133 = 3
bitCount8 134 = 3
bitCount8 135 = 4
bitCount8 136 = 2
bitCount8 137 = 3
bitCount8 138 = 3
bitCount8 139 = 4
bitCount8 140 = 3
bitCount8 141 = 4
bitCount8 142 = 4
bitCount8 143 = 5
bitCount8 144 = 2
bitCount8 145 = 3
bitCount8 146 = 3
bitCount8 147 = 4
bitCount8 148 = 3
bitCount8 149 = 4
bitCount8 150 = 4
bitCount8 151 = 5
bitCount8 152 = 3
bitCount8 153 = 4
bitCount8 154 = 4
bitCount8 155 = 5
bitCount8 156 = 4
bitCount8 157 = 5
bitCount8 158 = 5
bitCount8 159 = 6
bitCount8 160 = 2
bitCount8 161 = 3
bitCount8 162 = 3
bitCount8 163 = 4
bitCount8 164 = 3
bitCount8 165 = 4
bitCount8 166 = 4
bitCount8 167 = 5
bitCount8 168 = 3
bitCount8 169 = 4
bitCount8 170 = 4
bitCount8 171 = 5
bitCount8 172 = 4
bitCount8 173 = 5
bitCount8 174 = 5
bitCount8 175 = 6
bitCount8 176 = 3
bitCount8 177 = 4
bitCount8 178 = 4
bitCount8 179 = 5
bitCount8 180 = 4
bitCount8 181 = 5
bitCount8 182 = 5
bitCount8 183 = 6
bitCount8 184 = 4
bitCount8 185 = 5
bitCount8 186 = 5
bitCount8 187 = 6
bitCount8 188 = 5
bitCount8 189 = 6
bitCount8 190 = 6
bitCount8 191 = 7
bitCount8 192 = 2
bitCount8 193 = 3
bitCount8 194 = 3
bitCount8 195 = 4
bitCount8 196 = 3
bitCount8 197 = 4
bitCount8 198 = 4
bitCount8 199 = 5
bitCount8 200 = 3
bitCount8 201 = 4
bitCount8 202 = 4
bitCount8 203 = 5
bitCount8 204 = 4
bitCount8 205 = 5
bitCount8 206 = 5
bitCount8 207 = 6
bitCount8 208 = 3
bitCount8 209 = 4
bitCount8 210 = 4
bitCount8 211 = 5
bitCount8 212 = 4
bitCount8 213 = 5
bitCount8 214 = 5
bitCount8 215 = 6
bitCount8 216 = 4
bitCount8 217 = 5
bitCount8 218 = 5
bitCount8 219 = 6
bitCount8 220 = 5
bitCount8 221 = 6
bitCount8 222 = 6
bitCount8 223 = 7
bitCount8 224 = 3
bitCount8 225 = 4
bitCount8 226 = 4
bitCount8 227 = 5
bitCount8 228 = 4
bitCount8 229 = 5
bitCount8 230 = 5
bitCount8 231 = 6
bitCount8 232 = 4
bitCount8 233 = 5
bitCount8 234 = 5
bitCount8 235 = 6
bitCount8 236 = 5
bitCount8 237 = 6
bitCount8 238 = 6
bitCount8 239 = 7
bitCount8 240 = 4
bitCount8 241 = 5
bitCount8 242 = 5
bitCount8 243 = 6
bitCount8 244 = 5
bitCount8 245 = 6
bitCount8 246 = 6
bitCount8 247 = 7
bitCount8 248 = 5
bitCount8 249 = 6
bitCount8 250 = 6
bitCount8 251 = 7
bitCount8 252 = 6
bitCount8 253 = 7
bitCount8 254 = 7
bitCount8 255 = 8
