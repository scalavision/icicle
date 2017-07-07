{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Icicle.Runtime.Data.Array (
    Array(..)
  , ArrayIndex(..)
  , ArrayLength(..)
  , ArrayCapacity(..)
  , ArrayFootprint(..)

  , new
  , length
  , read
  , write
  , grow
  , replicate
  , fromVector
  , fromList
  , fromStringSegments
  , fromArraySegments
  , toVector
  , toList
  , toStringSegments
  , toArraySegments

  , makeDescriptor
  , takeDescriptor

  , unsafeRead
  , unsafeWrite
  , unsafeFromMVector
  , unsafeFromVector
  , unsafeFromStringSegments
  , unsafeFromArraySegments
  , unsafeViewMVector
  , unsafeViewVector

  , ArrayError(..)
  , renderArrayError

  -- * Internal
  , headerSize
  , elementSize
  , calculateCapacity
  , calculateFootprint
  , unsafeWriteLength
  , unsafeLengthPtr
  , unsafeElementPtr
  , unsafeAllocate
  , unsafeViewCString
  , checkElementSize
  , checkBounds
  , checkSegmentDescriptor
  ) where

import           Anemone.Foreign.Mempool (Mempool)
import qualified Anemone.Foreign.Mempool as Mempool

import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Primitive (PrimState)

import           Data.Bits (countLeadingZeros, shiftL)
import qualified Data.ByteString as ByteString
import           Data.ByteString.Internal (ByteString(..))
import qualified Data.Text as Text
import qualified Data.Vector as Boxed
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Storable.Mutable as MStorable
import           Data.Void (Void)
import           Data.Word (Word8)

import           Foreign.C.Types (CSize(..))
import           Foreign.C.String (CString)
import           Foreign.ForeignPtr (newForeignPtr_, withForeignPtr)
import           Foreign.Ptr (Ptr, plusPtr, castPtr)
import           Foreign.Storable (Storable(..))

import           GHC.Generics (Generic)

import           P hiding (length, toList)

import qualified Prelude as Savage

import           System.IO (IO)

import           X.Text.Show (gshowsPrec)
import           X.Control.Monad.Trans.Either (EitherT, left)


-- | An Icicle runtime array.
--
newtype Array =
  Array {
      unArray :: Ptr Void
    } deriving (Eq, Ord, Generic, Storable)

-- | An index in to an array.
--
newtype ArrayIndex =
  ArrayIndex {
      unArrayIndex :: Int64
    } deriving (Eq, Ord, Enum, Num, Real, Integral, Generic, Storable)

-- | The number of elements in the array.
--
newtype ArrayLength =
  ArrayLength {
      unArrayCount :: Int64
    } deriving (Eq, Ord, Enum, Num, Real, Integral, Generic, Storable)

-- | The number of elements the array can store without needing to allocate.
--
newtype ArrayCapacity =
  ArrayCapacity {
      unArrayCapacity :: Int64
    } deriving (Eq, Ord, Enum, Num, Real, Integral, Generic, Storable)

-- | The number of bytes the array occupies in memory, including the header.
--
newtype ArrayFootprint =
  ArrayFootprint {
      unArrayFootprint :: Int64
    } deriving (Eq, Ord, Enum, Num, Real, Integral, Generic, Storable)

data ArrayError =
    ArrayElementsMustBeWordSize !Int
  | ArrayIndexOutOfBounds !ArrayIndex !ArrayLength
  | ArraySegmentDescriptorMismatch !ArrayLength !ArrayLength
    deriving (Eq, Ord, Show)

renderArrayError :: ArrayError -> Text
renderArrayError = \case
  ArrayElementsMustBeWordSize n ->
    "Array elements must be exactly 8 bytes, found element with <" <> Text.pack (show n) <> " bytes>"
  ArrayIndexOutOfBounds (ArrayIndex ix) (ArrayLength len) ->
    "Array index <" <> Text.pack (show ix) <> "> was out of bounds [0, " <> Text.pack (show len) <> ")"
  ArraySegmentDescriptorMismatch (ArrayLength m) (ArrayLength n) ->
    "Array length <" <> Text.pack (show n) <> "> did not match segment descriptor length <" <> Text.pack (show m) <> ">"

instance Show Array where
  showsPrec =
    gshowsPrec

instance Show ArrayIndex where
  showsPrec =
    gshowsPrec

instance Show ArrayLength where
  showsPrec =
    gshowsPrec

instance Show ArrayCapacity where
  showsPrec =
    gshowsPrec

instance Show ArrayFootprint where
  showsPrec =
    gshowsPrec

headerSize :: Num a => a
headerSize =
  8
{-# INLINE headerSize #-}

elementSize :: Num a => a
elementSize =
  8
{-# INLINE elementSize #-}

-- | Calculate an array's capacity, from its current element count.
--
calculateCapacity :: ArrayLength -> ArrayCapacity
calculateCapacity (ArrayLength len) =
  if len < 4 then
    4
  else
    let
      !bits =
        64 - countLeadingZeros (len - 1)
    in
      ArrayCapacity (1 `shiftL` bits)
{-# INLINE calculateCapacity #-}

calculateFootprint :: ArrayCapacity -> ArrayFootprint
calculateFootprint (ArrayCapacity capacity) =
  ArrayFootprint $
    headerSize + elementSize * capacity
{-# INLINE calculateFootprint #-}

unsafeWriteLength :: Array -> ArrayLength -> IO ()
unsafeWriteLength (Array ptr) (ArrayLength len) =
  pokeByteOff ptr 0 len
{-# INLINE unsafeWriteLength #-}

unsafeLengthPtr :: Array -> Ptr Int64
unsafeLengthPtr (Array ptr) =
  castPtr ptr
{-# INLINE unsafeLengthPtr #-}

unsafeElementPtr :: Array -> Ptr a
unsafeElementPtr (Array ptr) =
  ptr `plusPtr` headerSize
{-# INLINE unsafeElementPtr #-}

unsafeAllocate :: Mempool -> ArrayFootprint -> IO Array
unsafeAllocate pool bytes =
  Array <$> Mempool.callocBytes pool (fromIntegral bytes) 1
{-# INLINE unsafeAllocate #-}

-- | Allocate an initialised array of the specified length.
--
new :: Mempool -> ArrayLength -> IO Array
new pool len = do
  let
    !bytes =
      calculateFootprint (calculateCapacity len)

  array <- unsafeAllocate pool bytes
  unsafeWriteLength array len

  pure array
{-# INLINABLE new #-}

length :: Array -> IO ArrayLength
length =
  fmap ArrayLength . peek . unsafeLengthPtr
{-# INLINE length #-}

checkElementSize :: Storable a => a -> EitherT ArrayError IO ()
checkElementSize x = do
 if sizeOf x /= elementSize then
   left $ ArrayElementsMustBeWordSize (sizeOf x)
 else
   pure ()
{-# INLINE checkElementSize #-}

checkBounds :: Array -> ArrayIndex -> EitherT ArrayError IO ()
checkBounds array (ArrayIndex ix) = do
  ArrayLength n <- liftIO $ length array
  if ix >= 0 && ix < n then
    pure ()
  else
    left $ ArrayIndexOutOfBounds (ArrayIndex ix) (ArrayLength n)
{-# INLINE checkBounds #-}

checkSegmentDescriptor :: Storable.Vector ArrayLength -> ArrayLength -> EitherT ArrayError IO ()
checkSegmentDescriptor ns m =
  let
    n =
      Storable.sum ns
  in
    if m == n then
      pure ()
    else
      left $ ArraySegmentDescriptorMismatch m n
{-# INLINE checkSegmentDescriptor #-}

unsafeRead :: Storable a => Array -> ArrayIndex -> IO a
unsafeRead array (ArrayIndex ix) =
  peekByteOff (unsafeElementPtr array) (fromIntegral (elementSize * ix))
{-# INLINE unsafeRead #-}

read :: forall a. Storable a => Array -> ArrayIndex -> EitherT ArrayError IO a
read array ix = do
  checkElementSize (Savage.undefined :: a)
  checkBounds array ix
  liftIO $ unsafeRead array ix
{-# INLINE read #-}

unsafeWrite :: Storable a => Array -> ArrayIndex -> a -> IO ()
unsafeWrite array (ArrayIndex ix) x = do
  pokeByteOff (unsafeElementPtr array) (fromIntegral (elementSize * ix)) x
{-# INLINE unsafeWrite #-}

write :: forall a. Storable a => Array -> ArrayIndex -> a -> EitherT ArrayError IO ()
write array ix x = do
  checkElementSize x
  checkBounds array ix
  liftIO $ unsafeWrite array ix x
{-# INLINE write #-}

grow :: Mempool -> Array -> ArrayLength -> IO Array
grow pool arrayOld@(Array ptrOld) lengthNew = do
  lengthOld <- length arrayOld

  let
    !capacityOld =
      calculateCapacity lengthOld

    !capacityNew =
      calculateCapacity lengthNew

  if capacityOld >= capacityNew then do
    unsafeWriteLength arrayOld lengthNew
    pure arrayOld
  else do
    let
      !bytesOld =
        calculateFootprint capacityOld

      !bytesNew =
        calculateFootprint capacityNew

    arrayNew@(Array ptrNew) <- unsafeAllocate pool bytesNew

    c_memcpy ptrNew ptrOld (fromIntegral bytesOld)
    unsafeWriteLength arrayNew lengthNew

    pure arrayNew
{-# INLINABLE grow #-}

replicate :: Storable a => Mempool -> ArrayLength -> a -> IO Array
replicate pool n x = do
  !array <- new pool n

  let
    loop !ix =
      if ix < fromIntegral n then do
        unsafeWrite array ix x
        loop (ix + 1)
      else
        pure array

  loop 0
{-# INLINABLE replicate #-}

unsafeViewMVector :: Storable a => Array -> IO (MStorable.MVector (PrimState IO) a)
unsafeViewMVector array = do
  !n <- length array
  !fp <- newForeignPtr_ (unsafeElementPtr array)
  pure $! MStorable.unsafeFromForeignPtr0 fp (fromIntegral n)
{-# INLINE unsafeViewMVector #-}

unsafeViewVector :: Storable a => Array -> IO (Storable.Vector a)
unsafeViewVector array =
  Storable.unsafeFreeze =<<! unsafeViewMVector array
{-# INLINE unsafeViewVector #-}

toVector :: forall a. Storable a => Array -> EitherT ArrayError IO (Storable.Vector a)
toVector array = do
  checkElementSize (Savage.undefined :: a)
  liftIO $!
    Storable.freeze =<<! unsafeViewMVector array
{-# INLINE toVector #-}

seqList :: [a] -> b -> b
seqList xs0 o =
  case xs0 of
    [] ->
      o
    x : xs ->
      x `seq` xs `seqList` o
{-# INLINE seqList #-}

unsafeToList :: Storable a => Array -> IO [a]
unsafeToList array = do
  xs <- Storable.toList <$> unsafeViewVector array
  xs `seqList` pure xs
{-# INLINE unsafeToList #-}

toList :: forall a. Storable a => Array -> EitherT ArrayError IO [a]
toList array = do
  checkElementSize (Savage.undefined :: a)
  liftIO $! unsafeToList array
{-# INLINE toList #-}

unsafeFromMVector :: Storable a => Mempool -> MStorable.MVector (PrimState IO) a -> IO Array
unsafeFromMVector pool vector = do
  let
    !n =
      MStorable.length vector

  !array <- new pool (fromIntegral n)

  let
    !dst =
      unsafeElementPtr array

  MStorable.unsafeWith vector $ \src ->
    c_memcpy dst src (fromIntegral (n * elementSize))

  pure array
{-# INLINABLE unsafeFromMVector #-}

unsafeFromVector :: Storable a => Mempool -> Storable.Vector a -> IO Array
unsafeFromVector pool vector =
  unsafeFromMVector pool =<<! Storable.unsafeThaw vector
{-# INLINE unsafeFromVector #-}

fromVector :: forall a. Storable a => Mempool -> Storable.Vector a -> EitherT ArrayError IO Array
fromVector pool vector = do
  checkElementSize (Savage.undefined :: a)
  liftIO $! unsafeFromVector pool vector
{-# INLINE fromVector #-}

fromList :: forall a. Storable a => Mempool -> [a] -> EitherT ArrayError IO Array
fromList pool xs =
  fromVector pool $! Storable.fromList xs
{-# INLINE fromList #-}

makeDescriptor :: Storable.Vector Int64 -> Storable.Vector ArrayLength
makeDescriptor =
  Storable.unsafeCast
{-# INLINE makeDescriptor #-}

takeDescriptor :: Storable.Vector ArrayLength -> Storable.Vector Int64
takeDescriptor =
  Storable.unsafeCast
{-# INLINE takeDescriptor #-}

unsafeFromStringSegments :: Mempool -> Storable.Vector ArrayLength -> ByteString -> IO Array
unsafeFromStringSegments pool ns (PS fp off0 _) =
  withForeignPtr fp $ \srcPtr -> do
    let
      !dstLength =
        Storable.length ns

    !dstArray <- new pool (fromIntegral dstLength)

    let
      loop (!ix, !off) n = do
        let
          !n_csize =
            fromIntegral n

          !n_int =
            fromIntegral n

        dstElemPtr <- Mempool.allocBytes pool (n_csize + 1)

        c_memcpy dstElemPtr (srcPtr `plusPtr` off) n_csize
        pokeByteOff dstElemPtr n_int (0 :: Word8)

        unsafeWrite dstArray ix dstElemPtr

        pure (ix + 1, off + n_int)

    Storable.foldM_ loop (0, off0) ns

    pure dstArray
{-# INLINABLE unsafeFromStringSegments #-}

fromStringSegments :: Mempool -> Storable.Vector ArrayLength -> ByteString -> EitherT ArrayError IO Array
fromStringSegments pool ns bs = do
  checkSegmentDescriptor ns . fromIntegral $ ByteString.length bs
  liftIO $! unsafeFromStringSegments pool ns bs
{-# INLINE fromStringSegments #-}

unsafeViewCString :: CString -> IO ByteString
unsafeViewCString ptr = do
  !n <- c_strlen ptr
  !fp <- newForeignPtr_ (castPtr ptr)
  pure $! PS fp 0 (fromIntegral n)
{-# INLINE unsafeViewCString #-}

toStringSegments :: Array -> IO (Storable.Vector ArrayLength, ByteString)
toStringSegments array = do
  !cstrs <- unsafeViewVector array
  !bss <- Boxed.mapM unsafeViewCString $ Storable.convert cstrs

  let
    !ns =
      Storable.convert $ fmap (fromIntegral . ByteString.length) bss

    !bs =
      ByteString.concat $ Boxed.toList bss

  pure (ns, bs)
{-# INLINE toStringSegments #-}

unsafeFromArraySegments :: Mempool -> Storable.Vector ArrayLength -> Array -> IO Array
unsafeFromArraySegments pool ns srcArray = do
  let
    !dstLength =
      Storable.length ns

  !dstArrayArray <- new pool (fromIntegral dstLength)

  let
    !srcPtr =
      unsafeElementPtr srcArray

    loop (!ix, !off) !n = do
      dstArray <- new pool n

      let
        !dstPtr =
          unsafeElementPtr dstArray

        !size =
          fromIntegral n * elementSize

      c_memcpy dstPtr (srcPtr `plusPtr` off) (fromIntegral size)

      unsafeWrite dstArrayArray ix dstArray

      pure (ix + 1, off + size)

  Storable.foldM_ loop (0, 0) ns

  pure dstArrayArray
{-# INLINABLE unsafeFromArraySegments #-}

fromArraySegments :: Mempool -> Storable.Vector ArrayLength -> Array -> EitherT ArrayError IO Array
fromArraySegments pool ns array = do
  m <- liftIO $ length array
  checkSegmentDescriptor ns m
  liftIO $! unsafeFromArraySegments pool ns array
{-# INLINE fromArraySegments #-}

toArraySegments :: Mempool -> Array -> IO (Storable.Vector ArrayLength, Array)
toArraySegments pool srcArrayArray = do
  !srcArrays <- unsafeViewVector srcArrayArray
  !ns <- Storable.mapM length srcArrays

  !dstArray <- new pool (Storable.sum ns)

  let
    !dstPtr =
      unsafeElementPtr dstArray

    loop !off !srcArray = do
      !n <- length srcArray

      let
        !srcPtr =
          unsafeElementPtr srcArray

        !size =
          fromIntegral n * elementSize

      c_memcpy (dstPtr `plusPtr` off) srcPtr (fromIntegral size)

      pure (off + size)

  Storable.foldM_ loop 0 srcArrays

  pure (ns, dstArray)
{-# INLINE toArraySegments #-}

foreign import ccall unsafe "string.h memcpy"
  c_memcpy :: Ptr a -> Ptr a -> CSize -> IO ()

foreign import ccall unsafe "string.h strlen"
  c_strlen :: CString -> IO CSize