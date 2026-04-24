#!/bin/bash

cat ~/.zhsrc > ./zshrc
SAVE_DATE=$(date +%s)



git add .
git commit -m "save config $SAVE_DATE"
git push origin main