use std/assert

def ok_test [test: string] { print $"Test '($test)': (ansi green)Ok.(ansi reset)" }

def err_test [test: string] { $"Test '($test)': (ansi red)failed(ansi reset)" }

zig build-exe rm.zig --name my_rm

# ------

let test = "Removing non empty dir without -r flag"
mkdir test_dir
touch test_dir/a.txt
touch test_dir/b.txt
assert error { ./my_rm test_dir e+o> /dev/null }
  (err_test $test)
ok_test $test
unlet $test
# ------

let test = "Removing non empty dir with -r flag"
mkdir test_dir
touch test_dir/a.txt
touch test_dir/b.txt
assert ((./my_rm -r test_dir | complete | get exit_code) == 0) (err_test $test)
ok_test $test
unlet $test

# ------

let test = "Parsing filenames that start with '-' without escaping it"
touch "-some.txt"
assert ((./my_rm "-some.txt" | complete | get exit_code) == 1) (err_test $test)
ok_test $test
unlet $test

# ------

let test = "Parsing filenames that start with '-' escaping it"
touch "-some.txt"
assert ((./my_rm -- "-some.txt" | complete | get exit_code) == 0) (err_test $test)
ok_test $test
unlet $test

# ------

let test = "-f should ignore missing files"
touch some.txt
assert ((./my_rm -f some.txt non_existent.txt | complete | get exit_code) == 0) (err_test $test)
ok_test $test
unlet $test

# ------

let test = "Error if -f is not provided when missing files"
touch some.txt
assert ((./my_rm some.txt non_existent.txt | complete | get exit_code) == 1) (err_test $test)
ok_test $test
unlet $test

# ------

let test = "Interactively delete a directory"
mkdir test_dir
touch test_dir/some.txt test_dir/other.txt
assert ((yes | ./my_rm -r -i test_dir | complete | get exit_code) == 0) (err_test $test)
ok_test $test
unlet $test

# ------

rm -rf test_dir
rm -f ./my_rm
print "Tests passed"

