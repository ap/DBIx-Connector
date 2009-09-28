#!/usr/bin/env perl -w

use strict;
use warnings;
use feature ':5.10';
use utf8;
use Test::More;

eval "use Test::Pod::Coverage 1.06";
plan skip_all => 'Test::Pod::Coverage 1.06 required' if $@;

all_pod_coverage_ok();
