
"File 1 contents" | save -f file1.txt
"File 2 contents" | save -f file2.txt
"File 3 contents" | save -f file3.txt
tar -cf files.tar file1.txt file2.txt file3.txt
rm ...("file{1..3}.txt" | str expand)
