<p align="center">
<img height="256" src="https://github.com/iina/iina/raw/master/iina/Assets.xcassets/AppIcon.appiconset/1024-1.png" />
</p>

<h1 align="center">IINA+</h1>

<p align="center">IINA+ is a special build of the <b>modern</b> video player <a href="https://github.com/iina/iina">IINA</a> with additional features and bugfixes.</p>

---

## Building

```bash
$ cp other/*-iina.rb $(brew --repo homebrew/core)/Formula # Copy custom mpv and ffmpeg formula into homebrew repo
$ make depends # Build dependencies
$ make build # Build iina itself
```
