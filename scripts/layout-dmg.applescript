on run arguments
    set diskFolder to (POSIX file (item 1 of arguments)) as alias
    tell application "Finder"
        set diskWindow to make new Finder window to diskFolder
        set current view of diskWindow to icon view
        set toolbar visible of diskWindow to false
        set statusbar visible of diskWindow to false
        set pathbar visible of diskWindow to false
        set bounds of diskWindow to {300, 200, 940, 560}
        set options to icon view options of diskWindow
        set arrangement of options to not arranged
        set icon size of options to 96
        set text size of options to 14
        set background picture of options to file ".background:background.png" of diskFolder
        set position of item "Music.app" of diskFolder to {160, 185}
        set position of item "Applications" of diskFolder to {480, 185}
        update diskFolder without registering applications
        delay 2
        close diskWindow
    end tell
end run
