dotNix
========

Manage dotnet installations that get updates quickly


Usage
=======

The flake is laid out as ``packages.<system>.<version>.<source>.<component>``.
Version keys use ``-`` in place of the dot (``"11-0"``, ``"8-0"``, ...).

Components
-----------

.. code-block:: nix

   dotnix.packages.<system>."11-0".stable.sdk
   dotnix.packages.<system>."11-0".stable.runtime
   dotnix.packages.<system>."11-0".stable.aspnetcore-runtime

``stable`` is the GA release feed and ``latest`` is the rolling daily/preview
feed. The ``default`` component is the combined toolchain:

.. code-block:: nix

   dotnix.packages.<system>."11-0".stable.default   # runtime + aspnetcore + sdk
   dotnix.packages.<system>.default                 # newest version, stable

Combining
----------

Build your own toolchain with ``combine``:

.. code-block:: nix

   let
     dotnet = dotnix.packages.${stdenv.hostPlatform.system};
   in
   dotnet.combine [
     dotnet."11-0".stable.runtime
     dotnet."11-0".stable.aspnetcore-runtime
     dotnet."11-0".stable.sdk
   ];

Runtime-only, for example:

.. code-block:: nix

   let
     dotnet = dotnix.packages.${stdenv.hostPlatform.system};
   in
   dotnet.combine [ dotnet."11-0".stable.runtime ];

The combined toolchain provides ``bin/dotnet`` plus the attributes
``buildDotnetModule`` expects from a ``dotnet-sdk`` package, so it can be used
directly:

.. code-block:: nix

   let
     dotnet = dotnix.packages.${stdenv.hostPlatform.system};
     dotnet-sdk = dotnet.combine [ dotnet."10-0".stable.sdk ];
     dotnet-runtime = dotnet.combine [ dotnet."10-0".stable.runtime ];
   in
   buildDotnetModule {
     pname = "example";
     version = "1.0.0";
     src = ./.;
     nugetDeps = ./deps.json;
     inherit dotnet-sdk dotnet-runtime;
   }

.. note::

   Unlike nixpkgs' ``dotnet-sdk``, dotnix does not ship the NuGet runtime/AOT
   packs (``Microsoft.NETCore.App.Runtime.*``, ``Microsoft.DotNet.ILCompiler``,
   ...). If your project restores a RID (self-contained or NativeAOT builds),
   regenerate the dependency lock with the toolchain you are building against:

   .. code-block:: console

      $ nix run .#<package>.fetch-deps

   Framework-dependent builds and ``buildDotnetGlobalTool`` work without it.

Cross RIDs
-----------

Every source also exposes its components keyed by upstream RID:

.. code-block:: nix

   dotnix.packages.<system>."8-0".stable.rids.sdk.linux-arm64

Also available: ``mkArtifact`` for raw per-RID artifacts.


Support
========

macOS and Linux generic support
