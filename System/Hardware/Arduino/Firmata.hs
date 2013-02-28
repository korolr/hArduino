-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Arduino.Firmata
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Implementation of the firmata protocol
-------------------------------------------------------------------------------

{-# LANGUAGE NamedFieldPuns #-}
module System.Hardware.Arduino.Firmata where

import Control.Concurrent  (newEmptyMVar, readMVar)
import Control.Monad       (when, unless, void)
import Control.Monad.State (StateT(..))
import Control.Monad.Trans (liftIO)
import Data.Bits           ((.&.), shiftR)
import Data.Word           (Word8)

import Data.Time      (getCurrentTime, utctDayTime)
import System.Timeout (timeout)

import System.Hardware.Arduino.Data
import System.Hardware.Arduino.Comm

import qualified System.Hardware.Arduino.Utils as U

-- | Retrieve the Firmata firmware version running on the Arduino. The first
-- component is the major, second is the minor. The final value is a human
-- readable identifier for the particular board.
queryFirmware :: Arduino (Word8, Word8, String)
queryFirmware = do
        send QueryFirmware
        r <- recv
        case r of
          Firmware v1 v2 m -> return (v1, v2, m)
          _                -> die "queryFirmware: Got unexpected response for query firmware call: " [show r]

-- | Delay the computaton for a given number of milli-seconds
delay :: Int -> Arduino ()
delay = liftIO . U.delay

-- | Time a given action, result is measured in micro-seconds.
time :: Arduino a -> Arduino (Int, a)
time a = do start <- tick
            r     <- a
            end   <- r `seq` tick
            return (toMicroSeconds (end - start), r)
 where -- tick gets the current time in picoseconds
       tick = do t <- liftIO $ utctDayTime `fmap` getCurrentTime
                 let precision = 1000000000000 :: Integer
                 return . round . (fromIntegral precision *) . toRational $ t
       toMicroSeconds :: Integer -> Int
       toMicroSeconds t = fromIntegral $ t `quot` 1000000

-- | Time-out a given action. Time-out amount is in micro-seconds.
timeOut :: Int -> Arduino a -> Arduino (Maybe a)
timeOut to (Arduino (StateT f)) = Arduino (StateT (\st -> do
        mbRes <- timeout to (f st)
        case mbRes of
          Nothing       -> return (Nothing, st)
          Just (a, st') -> return (Just a,  st')))

-- | Set the mode on a particular pin on the board
setPinMode :: Pin -> PinMode -> Arduino ()
setPinMode p' m = do
   p <- convertToInternalPin p'
   extras <- registerPinMode p m
   send $ SetPinMode p m
   mapM_ send extras

-- | Set or clear a digital pin on the board
digitalWrite :: Pin -> Bool -> Arduino ()
digitalWrite p' v = do
   -- first make sure we have this pin set as output
   p <- convertToInternalPin p'
   pd <- getPinData p
   when (pinMode pd /= OUTPUT) $ die ("Invalid digitalWrite call on pin " ++ show p)
                                       [ "The current mode for this pin is: " ++ show (pinMode pd)
                                       , "For digitalWrite, it must be set to: " ++ show OUTPUT
                                       , "via a proper call to setPinMode"
                                       ]
   case pinValue pd of
     Just (Left b) | b == v -> return () -- no change, nothing to do
     _                      -> do (lsb, msb) <- computePortData p v
                                  send $ DigitalPortWrite (pinPort p) lsb msb

-- | Send a pulse-out on a digital-pin for the given number of micro-seconds
pulseOut :: Pin -> Bool -> Int -> Arduino ()
pulseOut _ _ _ = return ()

-- | Turn on/off internal pull-up resistor on an input pin
pullUpResistor :: Pin -> Bool -> Arduino ()
pullUpResistor p' v = do
   -- first make sure we have this pin set as input
   p <- convertToInternalPin p'
   pd <- getPinData p
   when (pinMode pd /= INPUT) $ die ("Invalid turnOnPullUpResistor call on pin " ++ show p)
                                      [ "The current mode for this pin is: " ++ show (pinMode pd)
                                      , "For turnOnPullUpResistor, it must be set to: " ++ show INPUT
                                      , "via a proper call to setPinMode"
                                      ]
   (lsb, msb) <- computePortData p v
   send $ DigitalPortWrite (pinPort p) lsb msb

-- | Read the value of a pin in digital mode; this is a non-blocking call, returning
-- the current value immediately. See 'waitFor' for a version that waits for a change
-- in the pin first.
digitalRead :: Pin -> Arduino Bool
digitalRead p' = do
   -- first make sure we have this pin set as input
   p <- convertToInternalPin p'
   pd <- getPinData p
   when (pinMode pd /= INPUT) $ die ("Invalid digitalRead call on pin " ++ show p)
                                      [ "The current mode for this pin is: " ++ show (pinMode pd)
                                      , "For digitalWrite, it must be set to: " ++ show INPUT
                                      , "via a proper call to setPinMode"
                                      ]
   return $ case pinValue pd of
              Just (Left v) -> v
              _             -> False -- no (correctly-typed) value reported yet, default to False

-- | Wait for a change in the value of the digital input pin. Returns the new value.
-- Note that this is a blocking call. For a non-blocking version, see 'digitalRead', which returns the current
-- value of a pin immediately.
waitFor :: Pin -> Arduino Bool
waitFor p = head `fmap` waitAny [p]

-- | Wait for a change in any of the given pins. Once a change is detected, all the new values are
-- returned. Similar to 'waitFor', but is useful when we are watching multiple digital inputs.
waitAny :: [Pin] -> Arduino [Bool]
waitAny ps = map snd `fmap` waitGeneric ps

-- | Wait for any of the given pins to go from low to high. If all of the pins are high to start
-- with, then we first wait for one of them to go low, and then wait for one of them to go back high.
-- Returns the new values.
waitAnyHigh :: [Pin] -> Arduino [Bool]
waitAnyHigh ps = do
   curVals <- mapM digitalRead ps
   when (and curVals) $ void $ waitAnyLow ps   -- all are H to start with, wait for at least one to go low
   vs <- waitGeneric ps  -- wait for some change
   if (False, True) `elem` vs
      then return $ map snd vs
      else waitAnyHigh ps

-- | Wait for any of the given pins to go from high to low. If all of the pins are low to start
-- with, then we first wait for one of them to go high, and then wait for one of them to go back low.
-- Returns the new values.
waitAnyLow :: [Pin] -> Arduino [Bool]
waitAnyLow ps = do
   curVals <- mapM digitalRead ps
   unless (or curVals) $ void $ waitAnyHigh ps   -- all are L to start with, wait for at least one to go high
   vs <- waitGeneric ps  -- wait for some change
   if (True, False) `elem` vs
      then return $ map snd vs
      else waitAnyLow ps

-- | A utility function, waits for any change on any given pin
-- and returns both old and new values. It's guaranteed that
-- at least one returned pair have differing values.
waitGeneric :: [Pin] -> Arduino [(Bool, Bool)]
waitGeneric ps = do
   curVals <- mapM digitalRead ps
   semaphore <- liftIO newEmptyMVar
   let wait = do digitalWakeUp semaphore
                 liftIO $ readMVar semaphore
                 newVals <- mapM digitalRead ps
                 if curVals == newVals
                    then wait
                    else return $ zip curVals newVals
   wait

-- | Measure how long a pin stays the required value, with a potential time-out. The call @pulseIn p v to@
-- does the following:
--
--   * Waits until pin @p@ has value @v@. (If pin already has value @v@ then there's no wait.)
--
--   * Waits until pin @p@ has value @not v@.
--
--   * Returns, in micro-seconds, the duration the pin stayed @v@.
--
-- Time-out parameter is used as follows:
--
--    * If @to@ is @Nothing@, then 'pulseIn' will wait until the pin attains the value required and so long as it holds it.
-- 
--    * If @to@ is @Just t@ then, 'pulseIn' will stop if the above procedure does not complete within the given micro-seconds.
--    In this case, the overall return value is @Nothing@.
--
-- NB. Both the time-out value and the return value are given in micro-seconds.
pulseIn :: Pin -> Bool -> Maybe Int -> Arduino (Maybe Int)
pulseIn p v mbTo = case mbTo of
                    Nothing -> Just `fmap` pulse
                    Just to -> timeOut to pulse
  where waitTill f = do curVal <- digitalRead p
                        unless (f curVal) $ waitTill f
        pulse = do waitTill (== v)                  -- wait until pulse starts
                   (t, _) <- time $ waitTill (/= v) -- wait till pulse ends, measuring the time
                   return $ fromIntegral t

-- | Read the value of a pin in analog mode; this is a non-blocking call, immediately
-- returning the last sampled value. It returns @0@ if the voltage on the pin
-- is 0V, and @1023@ if it is 5V, properly scaled. (See `setAnalogSamplingInterval` for
-- sampling frequency.)
analogRead :: Pin -> Arduino Int
analogRead p' = do
   -- first make sure we have this pin set as analog
   p <- convertToInternalPin p'
   pd <- getPinData p
   when (pinMode pd /= ANALOG) $ die ("Invalid analogRead call on pin " ++ show p' ++ "(On board: " ++ show p ++ ")")
                                     [ "The current mode for this pin is: " ++ show (pinMode pd)
                                     , "For analogRead, it must be set to: " ++ show ANALOG
                                     , "via a proper call to setPinMode"
                                     ]
   return $ case pinValue pd of
              Just (Right v) -> v
              _              -> 0 -- no (correctly-typed) value reported yet, default to False

-- | Set the analog sampling interval, in milliseconds. Arduino uses a default of 19ms to sample analog and I2C
-- signals, which is fine for many applications, but can be modified if needed. The argument
-- should be a number between @10@ and @16384@; @10@ being the minumum sampling interval supported by Arduino
-- and @16383@ being the largest value we can represent in 14 bits that this message can handle. (Note that
-- the largest value is just about @16@ seconds, which is plenty infrequent for all practical needs.)
setAnalogSamplingInterval :: Int -> Arduino ()
setAnalogSamplingInterval i
  | i < 10 || i > 16383
  = die ("hArduino: setAnalogSamplingInterval: Allowed interval is [10, 16383] ms, received: " ++ show i) []
  | True
  = send $ SamplingInterval (fromIntegral lsb) (fromIntegral msb)
  where lsb = i .&. 0x7f
        msb = (i `shiftR` 7) .&. 0x7f
