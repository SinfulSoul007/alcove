#!/usr/bin/env perl
# Copy into the pinned checkout's Tools/Scripts so source discovery stays upstream.
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use webkitdirs ();
use File::Copy qw(copy);
use File::Path qw(make_path);

die "This launcher takes no arguments\n" if @ARGV;
@ARGV = ('--no-use-workspace');
my @options = webkitdirs::XcodeOptions();
die "Unexpected unconsumed build arguments\n" if @ARGV;
die "Unexpected project selection in upstream options\n"
    if grep { $_ eq '-workspace' || $_ eq '-project' || $_ eq '-scheme' || $_ eq '-target' } @options;
my $source = webkitdirs::sourceDir();
my $schemes = "$source/Source/WebKit/WebKit.xcodeproj/xcshareddata/xcschemes";
make_path($schemes);
copy("$FindBin::Bin/AlcoveWebKit.xcscheme", "$schemes/AlcoveWebKit.xcscheme")
    or die "Cannot publish project build scheme: $!\n";
chdir $source or die "Cannot enter pinned source: $!\n";
exec 'xcodebuild', '-project', "$source/Source/WebKit/WebKit.xcodeproj", '-scheme', 'AlcoveWebKit',
    @options, 'GCC_GENERATE_DEBUGGING_SYMBOLS=NO', 'COMPILER_INDEX_STORE_ENABLE=NO';
die "Cannot launch Xcode: $!\n";
