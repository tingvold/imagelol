#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Getopt::Long;
use File::Find;

# Load imagelol
my $imagelol_dir;
BEGIN { $imagelol_dir = "/srv/bilder/imagelol"; }
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

unless (-d $src_dir) die error_log("Source directory doesn't exist. Exiting....");
unless (-d $dst_dir) die error_log("Destination directory doesn't exist. Exiting....");

# Import images
sub import_images{
	# Find and import all images
	find(\&copy_images, $src_dir);
}

# Copy images
sub copy_images{
	my $image_full_path = "$File::Find::name";
	my $image_file = "$_";
	
	if ($image_file =~ m/^.+\.$config{div}->{image_filenames}$/){
	
		log_it("Copying image '$image_full_path'...");
		
	}
}

# We only want 1 instance of this script running
# Check if already running -- if so, abort.
unless (flock(DATA, LOCK_EX|LOCK_NB)) {
	die error_log("$0 is already running. Exiting.");
}

# Let's start...
my $time_start = time();

# Import images...
import_images();

# How long did we run
my $runtime = time() - $time_start;
log_it("Took $runtime seconds to complete.");

__DATA__
Do not remove. Makes sure flock() code above works as it should.
