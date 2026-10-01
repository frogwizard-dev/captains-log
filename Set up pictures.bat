@echo off
title Captain's Log - set up pictures
rem Lets Captain's Log show your screenshots. The game only reads files inside Interface\AddOns,
rem so this links the Screenshots folder in as Interface\AddOns\CaptainsLogShots (a junction:
rem nothing is copied or moved, and deleting the link never touches your screenshots). It has
rem no .toc, so it isn't an addon and updates leave it alone.
rem
rem It also lists the screenshots already there (in Shots.lua beside this file), so the book can
rem add the ones it has no card for. Run it again any time to bring in older screenshots.

for %%I in ("%~dp0..\..\..") do set "GAME=%%~fI"
set "LINK=%GAME%\Interface\AddOns\CaptainsLogShots"
set "SHOTS=%GAME%\Screenshots"
set "LIST=%~dp0Shots.lua"

if not exist "%SHOTS%" mkdir "%SHOTS%"

if exist "%LINK%" (
    echo Pictures are already set up.
) else (
    mklink /J "%LINK%" "%SHOTS%" >nul
    if errorlevel 1 (
        echo Couldn't set up pictures. Is the game's folder read-only?
        goto done
    )
    echo Pictures are set up.
)

set COUNT=0
> "%LIST%" echo -- The screenshots in your Screenshots folder, written by "Set up pictures.bat".
>> "%LIST%" echo CaptainsLogShotList = {
for %%F in ("%SHOTS%\WoWScrnShot_*.jpg" "%SHOTS%\WoWScrnShot_*.png" "%SHOTS%\WoWScrnShot_*.tga") do (
    >> "%LIST%" echo     "%%~nxF",
    set /a COUNT+=1
)
>> "%LIST%" echo }
echo Listed %COUNT% screenshots for the book.
echo.
echo In the game: turn on pictures in the book's Pictures page ("It's set up") if you
echo haven't, and type /reload to add screenshots the book doesn't have yet.

:done
echo.
pause
