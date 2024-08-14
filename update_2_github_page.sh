#!/bin/bash
hugo --gc --minify --cleanDestinationDir
git add . && git commit -m "update blog" && git push orgin main:main