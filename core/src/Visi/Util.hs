module Visi.Util (flatten, VisiError(TypeError), ThrowsError, vtrace) where

{- ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is Visi.io.
 *
 * The Initial Developer of the Original Code is
 * David Pollak.
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * ***** END LICENSE BLOCK ***** -}

-- | flatten a List
flatten :: [[a]] -> [a]
flatten x = x >>= (\a -> a)

-- | Trace that you can disable
vtrace :: String -> a -> a
vtrace _ a = a
-- vtrace msg a = trace msg a

data VisiError = TypeError String deriving (Show, Eq)

type ThrowsError = Either VisiError