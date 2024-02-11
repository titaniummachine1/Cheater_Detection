@echo off

node bundle.js
move /Y "Cheater_Detection.lua" "%localappdata%"
exit