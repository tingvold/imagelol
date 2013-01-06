#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Getopt::Long;

# Load imagelol
my $imagelol_dir;
BEGIN { $imagelol_dir = "/opt/userlol"; }
use lib $imagelol_dir;
use imagelol;
my $imagelol = imagelol->new();
my %config = $imagelol->get_config();

# Log
sub log_it{
	$imagelol->log_it("import-images", "@_");
}

# Logs debug-stuff if debug has been turned on
sub debug_log{
	$imagelol->debug_log("import-images", "@_");
}

# Logs error-stuff
sub error_log{
	$imagelol->error_log("import-images", "@_");
}

# Get options
my ($src_dir, $dst_dir);
if (@ARGV > 0) {
	GetOptions(
	's|src|source=s'	=> \$src_dir,
	'd|dst|destination=s'	=> \$dst_dir,
	)
}

# Set paths from config, unless provided as parameter
$src_dir = $config{path}->{import_folder} unless $src_dir;
$dst_dir = $config{path}->{archive_folder} unless $dst_dir;

print "src: $src_dir\n";
print "dst: $dst_dir\n";


