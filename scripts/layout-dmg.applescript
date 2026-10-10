on run arguments
    set diskFolder to (POSIX file (item 1 of arguments)) as alias
    set backgroundFile to (POSIX file ((item 1 of arguments) & "/.background/background.png")) as alias
    tell application "Finder"
        set diskWindow to make new Finder window to diskFolder
        set current view of diskWindow to icon view
        set toolbar visible of diskWindow to false
        set statusbar visible of diskWindow to false
        set pathbar visible of diskWindow to false
        set bounds of diskWindow to {300, 200, 940, 630}
        set options to icon view options of diskWindow
        set arrangement of options to not arranged
        set icon size of options to 96
        set text size of options to 14
        set background picture of options to backgroundFile
        set position of item "Music.app" of diskWindow to {160, 185}
        set position of item "Applications" of diskWindow to {480, 185}
        update diskFolder without registering applications
        close diskWindow
        -- Finder saves icon positions asynchronously; reopen before finalizing the image.
        delay 1
        set diskWindow to make new Finder window to diskFolder
        delay 3
        -- Hiding the toolbar can shift icons; restore their positions after the window settles.
        set position of item "Music.app" of diskWindow to {160, 185}
        set position of item "Applications" of diskWindow to {480, 185}
        close diskWindow
        delay 2
    end tell
end run
