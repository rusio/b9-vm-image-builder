{-# LANGUAGE DeriveDataTypeable #-}
{-| Data types describing the execution environment
    of virtual machine builds.
    'ExecEnv', 'Resources' and 'SharedDirectory' describe how
    "B9.LibVirtLXC" should configure and execute
    build scripts, as defined in "B9.ShellScript" and "B9.Vm".
    -}
module B9.ExecEnv (
    ExecEnv(..),
    Resources(..),
    noResources,
    SharedDirectory(..),
    CPUArch(..),
    RamSize(..),
    ) where

import Data.Data
import Data.Monoid

import B9.DiskImages

data ExecEnv = ExecEnv { envName :: String
                       , envImageMounts :: [Mounted Image]
                       , envSharedDirectories :: [SharedDirectory]
                       , envResources :: Resources
                       }

data SharedDirectory = SharedDirectory FilePath MountPoint
                     | SharedDirectoryRO FilePath MountPoint
                     | SharedSources MountPoint
  deriving (Read, Show, Typeable, Data, Eq)

data Resources = Resources { maxMemory :: RamSize
                           , cpuCount :: Int
                           , cpuArch :: CPUArch
                           }
  deriving (Read, Show, Typeable, Data)

instance Monoid Resources where
  mempty = Resources mempty 1 mempty
  mappend (Resources m c a) (Resources m' c' a') = Resources (m <> m') (max c c') (a <> a')

noResources :: Resources
noResources = mempty

data CPUArch = X86_64
             | I386
  deriving (Read, Show, Typeable, Data, Eq)

instance Monoid CPUArch where
    mempty = I386
    I386 `mappend` x = x
    X86_64 `mappend` _ = X86_64

data RamSize = RamSize Int SizeUnit
             | AutomaticRamSize
  deriving (Eq, Read, Show, Ord, Typeable, Data)

instance Monoid RamSize where
    mempty = AutomaticRamSize
    AutomaticRamSize `mappend` x = x
    x `mappend` AutomaticRamSize = x
    r `mappend` r' = max r r'
