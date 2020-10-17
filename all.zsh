#!/usr/bin/zsh

chk=$@[(r)-c]

args=("${(@)@:#-c}")

if [[ $#@ == 1 ]]
then
    out=""
else
    out=(-o out)
fi

for grc in calendar*.grc occupations.grc stack.grc count.grc
do
    ./graph.rb $chk -r $grc $out $args
done
