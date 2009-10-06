#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More;

eval "use Test::Pod::Coverage 1.06";
plan skip_all => 'Test::Pod::Coverage 1.06 required' if $@;

all_pod_coverage_ok();
