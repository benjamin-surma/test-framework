module Test.Framework.Improving (
        (:~>)(..), 
        ImprovingIO, yieldImprovement, runImprovingIO, liftIO,
        timeoutImprovingIO, maybeTimeoutImprovingIO
    ) where

import Test.Framework.TimeoutIO

import Control.Concurrent
import Control.Monad


data i :~> f = Finished f
             | Improving i (i :~> f)

instance Functor ((:~>) i) where
    fmap f (Finished x)    = Finished (f x)
    fmap f (Improving x i) = Improving x (fmap f i)


newtype ImprovingIO i f a = IIO { unIIO :: Chan (Either i f) -> IO a }

instance Functor (ImprovingIO i f) where
    fmap = liftM

instance Monad (ImprovingIO i f) where
    return x = IIO (const $ return x)
    ma >>= f = IIO $ \chan -> do
                    a <- unIIO ma chan
                    unIIO (f a) chan

yieldImprovement :: i -> ImprovingIO i f ()
yieldImprovement improvement = IIO $ \chan -> do
    -- Whenever we yield an improvement, take the opportunity to yield the thread as well.
    -- The idea here is to introduce frequent yields in users so that if e.g. they get killed
    -- by the timeout code then they know about it reasonably promptly.
    yield
    writeChan chan (Left improvement)

runImprovingIO :: ImprovingIO i f f -> IO (i :~> f, IO ())
runImprovingIO iio = do
    chan <- newChan
    let action = do
        result <- unIIO iio chan
        writeChan chan (Right result)
    improving_value <- getChanContents chan
    return (reifyListToImproving improving_value, action)

reifyListToImproving :: [Either i f] -> (i :~> f)
reifyListToImproving (Left improvement:rest) = Improving improvement (reifyListToImproving rest)
reifyListToImproving (Right final:_)         = Finished final
reifyListToImproving []                      = error "reifyListToImproving: list finished before a final value arrived"

liftIO :: IO a -> ImprovingIO i f a
liftIO io = IIO $ const io

timeoutImprovingIO :: Seconds -> ImprovingIO i f a -> ImprovingIO i f (Maybe a)
timeoutImprovingIO seconds iio = IIO $ \chan -> timeoutIO seconds $ unIIO iio chan

maybeTimeoutImprovingIO :: Maybe Seconds -> ImprovingIO i f a -> ImprovingIO i f (Maybe a)
maybeTimeoutImprovingIO Nothing        = fmap Just
maybeTimeoutImprovingIO (Just timeout) = timeoutImprovingIO timeout