
-- | Signals represent continuous time varying state and activity.
-- Conceptually, a signal is similar to:
--
--    type Signal a = T -> Maybe a
--
-- The value is 'Nothing' while the signal is inactive; effectively
-- the signal doesn't exist for that period. An active signal will
-- hold a value (which might vary with time). The `activity cycle` 
-- of any signal is achieved by reducing values to unit, Signal (). 
--
-- For Sirea, only discrete-varying signals are supported. These
-- signals change discretely, at specific instants on a continuous 
-- timeline, then hold constant for a non-zero duration between each
-- change. A well-behaved discrete-varying behavior only changes a
-- finite count in any bounded period, avoiding Zeno's paradox. A 
-- sampling method exists to discover instants of potential change.
--
-- RDP users never work with signals directly, but foreign service
-- adapters, FFI, and similar will need to work with signals. Sirea
-- users will sometimes be writing those adapters.
--
module Sirea.Signal 
 ( Sig
 , listToSig, sigToList
 , s_sample, s_sample_d, s_trim
 , s_never, s_always
 , s_const 
 , s_fmap, s_full_map
 , s_ap
 , s_zip, s_full_zip
 --, s_weave, s_full_weave
 , s_mask
 , s_merge
 , s_switch, s_switch'
 , s_is_final, s_term
 , s_delay, s_peek
 , s_adjn, s_adjeqf
 --, s_strat
 -- instances: functor, applicative, alternative
 ) where

import Sirea.Time
import Sirea.Internal.SigType
import Sirea.Internal.DiscreteTimedSeq
import Control.Exception (assert)
import Control.Applicative
import Data.Maybe (isNothing)

instance Functor Sig where
    fmap  = s_fmap
    (<$)  = s_const

instance Applicative Sig where
    pure  = s_always
    (<*>) = s_ap
    (<*)  = s_mask
    (*>)  = flip s_mask

instance Alternative Sig where
    empty = s_never
    (<|>) = s_merge

-- | listToSig allows developers to turn a list of signal updates
-- into a signal. The list must be ordered in strict monotonic time,
-- which means no repeating times. It should not be divergent when
-- computing the next change. The value prior to the first update is
-- also provided. 
listToSig :: (Maybe a) -> [(T,Maybe a)] -> Sig a
listToSig v0 = mkSig v0 . ds_fromList 

-- | Sample a signal for its value at given instant. The signal
-- may be inactive at the given instant, in which case 'Nothing'
-- is returned. In addition, the trimmed signal is returned for 
-- further sampling (to avoid redundant computation)
s_sample :: Sig a -> T -> (Maybe a, Sig a)
s_sample s0 tm =
    let sf = s_trim s0 tm in
    (s_head sf, sf)

-- | Trim a signal to clear unnecessary history data. Collecting the
-- past while computing the future can ensure predictable space cost
-- and avoid space-time leaks.
s_trim :: Sig a -> T -> Sig a
s_trim s0 tm = 
    let (x,ds) = ds_query (s_head s0) tm (s_tail s0) in
    mkSig x ds

-- | Discrete sample of a signal: rather than finding a value at a
-- given instant, returns the first instant of change between two
-- times, excluding the lower bound but including the upper. 
--
--    fst $ s_sample_d sig lower upper =
--       Just (t, v) -- potential change at instant t to value v
--         invariant: lower < t <= upper
--         note: v is sample; might be Nothing for inactive signals
--       Nothing -- no change in the given range
--
-- Note that there are no guarantees that v is actually a change in
-- value. That is, it could equal the prior v value. Use of s_filter 
-- can help eliminate duplicates and avoid redundant computations, 
-- but must be applied judiciously (or itself becomes redundant).
--
-- A trimmed signal for further sampling is also returned. The trim
-- is up to 'upper' if no sample was found, otherwise only up to 
-- the discovered sample. One can use this to efficiently acquire
-- multiple samples in a given time range (though sigToList is more
-- efficient).
s_sample_d :: Sig a -> T -> T -> (Maybe (T, Maybe a), Sig a)
s_sample_d s0 tLower tUpper =
    assert (tLower < tUpper) $
    let x  = s_head s0 in
    let xs = s_tail s0 in
    case dstep xs tUpper of
        DSDone -> (Nothing, mkSig x ds_done)
        DSWait xs' -> (Nothing, mkSig x xs')
        DSNext tx x' xs' ->
            if tLower < tx
                then (Just (tx,x'), mkSig x' xs')
                else s_sample_d (mkSig x' xs') tLower tUpper


-- | sigToList will obtain the [(T,Maybe a)] states in a given time
-- range, similar to s_sample_d. Note that there will always be at
-- least one value for the signal's state at the lower bound time.
sigToList :: Sig a -> T -> T -> [(T, Maybe a)]
sigToList s0 tLower tUpper =
    assert (tLower <= tUpper) $
    let (x,xs) = ds_query (s_head s0) tLower (s_tail s0) in
    (tLower,x):(ds_takeList tUpper xs)

-- | a signal that is never active (`Nothing` at all times)
-- Same as `empty` from Alternative.
s_never  :: Sig a_
s_never = mkSig Nothing ds_done

-- | a signal that is always active with a specific value c
-- Same as `pure` from Applicative.
s_always :: c -> Sig c
s_always c = mkSig (Just c) ds_done

-- | replace all values in a signal with a constant c, such that the
-- signal varies between Just c and Nothing. This will also filter 
-- unnecessary updates from values that are now known to be equal.
s_const :: c -> Sig a_ -> Sig c
s_const c s0 = 
    case s_head s0 of
        Nothing -> mkSig Nothing (ds_const0 c (s_tail s0))
        Just _  -> mkSig (Just c) (ds_const1 c (s_tail s0))

-- | Map applies a function across the active values of a signal.
-- Same as the Functor fmap.
s_fmap :: (a -> b) -> Sig a -> Sig b
s_fmap = s_full_map . fmap

-- | Full map applies a function across all values, including 
-- inactivity of the signal. 
s_full_map :: (Maybe a -> Maybe b) -> Sig a -> Sig b
s_full_map f s0 = mkSig y ys
    where y = f (s_head s0)
          ys = ds_map f (s_tail s0)

-- | Ap applies one signal to another. 
s_ap :: Sig (a -> b) -> Sig a -> Sig b
s_ap = s_full_zip (<*>)

-- | zip two signals using a provided function. The resulting signal
-- is active only when both inputs are active. 
s_zip :: (a -> b -> c) -> Sig a -> Sig b -> Sig c
s_zip = s_full_zip . liftA2

-- | Full zip applies a function across periods of inactivity, too.
s_full_zip :: (Maybe a -> Maybe b -> Maybe c) -> Sig a -> Sig b -> Sig c
s_full_zip jf sa sb = mkSig (f b) (ds_ap f b fs bs)
    where f  = jf (s_head sa)
          fs = ds_map jf (s_tail sa)
          b  = s_head sb
          bs = s_tail sb

{-
-- IDEA: `weave` functions that pick one element as the contributing
-- element at any given step. This is a more specialized `zip` that
-- can avoid the interruptions due to updates in the unused element.
-- This becomes the generic basis for mask & merge, and is useful for
-- the single-element minimax demand monitors. 
--
-- Intermediate, it is also possible to have a weave-zip that can
-- identify when only one of the two inputs contributes. However,
-- this might also be achieved via a merge of a weave and a zip.
--
-- Will need to find a sensible API for these before progressing.

-- | to `weave` a value is a specialized form of `zip`; the idea is
-- that only one signal contributes to the weave at any given time,
-- so we can eliminate some updates from the signal that does not
-- contribute at that time.
-- This is tested by `a -> b -> Bool`. If True, the left side will
-- contribute. If False, the right side will contribute. 
s_weave :: (a -> a -> Bool) -> Sig a -> Sig a -> Sig a
s_weave w = s_full_weave w'
    where w' _ Nothing = True
          w' Nothing _ = False
          w' (Just a0) (Just a1) = w a0 a1

-- could add an a->b->c for a weave-zip.

-- | full weave provides some more flexibility on how to merge in
-- case of Nothing values. 
s_full_weave :: (Maybe a -> Maybe a -> Bool) 
             -> Sig a -> Sig a -> Sig a
-}

-- | Mask one signal with the activity profile of another. That is,
-- the resulting signal is only active when both input signals are
-- active, but the value is always from the signal on the left.
--    s_mask = s_zip const (but somewhat optimized)
s_mask :: Sig a -> Sig b_ -> Sig a
s_mask sa sb = 
    case s_head sb of
        Nothing -> mkSig Nothing (tail_with ds_mask0)
        _       -> mkSig (s_head sa) (tail_with ds_mask1)
    where tail_with msk = msk (s_head sa) (s_tail sa) (s_tail sb)



-- | Merge two signals by using the left signal when it is active,
-- otherwise the right signal.
--    s_merge = s_full_zip (<|>)
-- But is much more optimizable than general zips.
s_merge :: Sig a -> Sig a -> Sig a
s_merge sl sr =
    let sl0 = s_head sl in
    let sr0 = s_head sr in
    let sltl = s_tail sl in
    let srtl = s_tail sr in
    -- note that ds_merge is flipped, favoring RHS.
    let smtl = ds_merge sr0 sl0 srtl sltl in 
    mkSig (sl0 <|> sr0) smtl

-- | Switch from the left signal to the right signal at a given
-- instant. The left signal is used until just before the instant,
-- then the right signal is used starting at that instant.
s_switch :: Sig a -> T -> Sig a -> Sig a
s_switch s0 t sf =
    mkSig (s_head s0) (ds_sigup (s_tail s0) t (s_head sf) (s_tail sf))

-- | Switch but with slightly stricter semantics - ensures that the
-- spine of the signal up to T is evaluated. Intention to simplify
-- GC of values that are no longer applicable. 
s_switch' :: Sig a -> T -> Sig a -> Sig a
s_switch' s0 t sf =
    mkSig (s_head s0) (ds_sigup' (s_tail s0) t (s_head sf) (s_tail sf))

-- | Test whether a signal is in its final state from a particular
-- instant. This is useful for garbage collection and optimizations.
-- This is a semi-decision; it may return False if the answer is
-- unknown (or would risk divergence) at the given instant.
s_is_final :: Sig a -> T -> Bool
s_is_final s0 tm =
    let (_,ds) = ds_query (s_head s0) tm (s_tail s0) in
    case dstep ds tm of
        DSDone -> True
        _ -> False

-- | Test whether a signal has terminated after a given instant.
--     s_term s t = isNothing (s_sample s t) && (s_is_final s t)
s_term :: Sig a -> T -> Bool
s_term s0 tm =
    let (v,ds) = ds_query (s_head s0) tm (s_tail s0) in
    let isFinal = case dstep ds tm of 
                    DSDone -> True
                    _ -> False
    in isNothing v && isFinal

-- | s_adjn will eliminate adjacent `Nothing` values. These might 
-- exist after s_full_map to filter a signal by its values.
s_adjn :: Sig a -> Sig a
s_adjn s0 =
    case s_head s0 of
        Nothing -> mkSig Nothing (ds_adjn0 (s_tail s0))
        hd      -> mkSig hd (ds_adjn1 (s_tail s0))


-- | Delay a signal - time-shifts the signal so that the same values
-- are observed at a later instant in time. Models latency. Activity
-- is also time-shifted.
--
-- Note: for RDP it is necessary to compute static delays, so this
-- function should never be used in FFI adapters. Wrap the adapter
-- with RDP 'bdelay' behaviors instead, if necessary.
s_delay :: DT -> Sig a -> Sig a
s_delay dt s0 = mkSig (s_head s0) (ds_delay dt (s_tail s0))

-- utility for s_delay (specific to DT, so in this file)
ds_delay :: DT -> DSeq a -> DSeq a
ds_delay dt ds = DSeq $ \ tq ->
    case dstep ds (subtractTime tq dt) of
        DSDone -> DSDone
        DSWait ds' -> DSWait (ds_delay dt ds')
        DSNext tm v ds' -> DSNext (addTime tm dt) v (ds_delay dt ds')


-- | Peek is for anticipating a signal. Unlike delay, this does not
-- change the activity of a signal; instead, it reports that the
-- future signal is inactive as information in the resulting signal.
--    s_peek :: DT -> Sig a -> Sig (Either a ())
-- The `()` indicates that we anticipate the future signal to be
-- inactive. Use of `Either` (instead of Maybe) supports split.
--
-- The ability to observe future inactivity is useful for resource
-- control. 
s_peek  :: DT -> Sig a -> Sig (Either a ())
s_peek dt s0 = 
    let shifted = s_delay (negate dt) (s_fmap Left s0) in
    let stopped = s_const (Right ()) s0 in
    let merged  = s_merge shifted stopped in 
    let masked  = s_mask merged stopped in
    masked

-- | Erase adjacent signal values that are equal in value. You can
-- provide the equality function that compares one value to another.
-- This will eliminate redundant updates. It is intended for 
-- performance, but must be used judiciously (the filter itself has 
-- a cost).
s_adjeqf :: (a -> a -> Bool) -> Sig a -> Sig a
s_adjeqf eq s0 = 
    let x = s_head s0 in
    let xs = s_tail s0 in
    mkSig x (ds_adjeqfx meq x xs)
    where meq Nothing Nothing = True
          meq (Just x) (Just y) = eq x y
          meq _ _ = False

-- TODO?
-- Apply a strategy to initialize parallel evaluation of a signal 
-- during sampling. I.e. if you sample at time T, may initialize 
-- parallel computation of the signal at time T+dt. 
-- s_strat :: DT -> Sig (Eval a) -> Sig a


-- IDEAS:
--  choke: should be done with intermediate state, as RDP behavior,
--    since it means we're looking at past values or tracking time.
--  improve s_adjeqf handoff? maybe some sort of `improving` value
--    model fot the update times? seems complicated.
--  

