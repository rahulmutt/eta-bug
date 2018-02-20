# Shake 0.16.2 with Eta

This causes a bug:

```
[58 of 58] Compiling Development.Shake.Config ( src/Development/Shake/Config.hs, dist/build/Development/Shake/Config.jar )

<no location info>:
    eta: panic! (the 'impossible' happened)
  (Eta version 0.7.0b2):
	unequal assigmnents

Please report this as a Eta bug: http://github.com/typelead/eta/issues
```

### Building

```
etlas install --dependencies-only
etlas build
```

### Debug Outputs


See `Config.dump-cg-trace` and `Config.ddump-stg` for more info.
