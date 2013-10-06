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
	$imagelol->log_it("make-album", "@_");
}

# Logs debug-stuff if debug has been turned on
sub debug_log{
	$imagelol->debug_log("make-album", "@_");
}

# Logs error-stuff
sub error_log{
	$imagelol->error_log("make-album", "@_");
	return 0;
}

# Get options
my ($path_search, $img_range, $album_name, $album_description, $delete);
if (@ARGV > 0) {
	GetOptions(
	'search=s'		=> \$path_search,
	'range=s'		=> \$img_range,
	'album=s'		=> \$album_name,
	'desc|description=s'	=> \$album_description,
	'del|delete'		=> \$delete,
	)
}

#########
######### TODO
#########
## - Make it so that if $delete is false, and no $description is present, it should ask about it before adding stuff
## - 

# Return images from DB matching range, etc
sub get_images{
	
}

# Add images to album -- create album if needed
sub add_images_to_album{
	# First we make a few assumptions
	# We actually expect the image-format to be in a specific way (IMG_XXXX.ext)
	# If this syntax changes, this part needs to change accordingly
	
	if($imglol->album_exists($album_name)){
		# Update if album exists
		
		$imagelol->set_new_imgrange($img_range);
		
	} else {
		# Album does not exists -- let's create it
		
		## TODO: Ask about adding description if not existing
		
		$imagelol->create_album();
	}
	
}

# Delete images from album
sub delete_images_from_album{
	# $img_range sets the new range -- the old value is ignored
}

# Update description on album
sub update_album_description{
	
}

# We only want 1 instance of this script running
# Check if already running -- if so, abort.
unless (flock(DATA, LOCK_EX|LOCK_NB)) {
	die error_log("$0 is already running. Exiting.");
}

# Let's start...
my $time_start = time();
$imagelol->connect();

# Start the logic
if($delete){
	# If we want to delete images from an album, we need some other stuff
	if($album_name && $img_range){
		if(($album_name =~ m//))
		delete_images_from_album();
	} else {
		return error_log("Need to fill out all the required parameters.");
	}
} else {
	# If we don't want to delete, we expect some other parameters
	if($img_range || $path_search){
		if($path_search && $img_range){
			add_images_to_album();
		} else {
			return error_log("Need to fill out all the required parameters.");
		}
	} else {
		if($album_name && $album_description){
			update_album_description();
		} else {
			return error_log("Need to fill out all the required parameters.");
		}
	}
}

$imagelol->disconnect();

# How long did we run
my $runtime = time() - $time_start;
log_it("Took $runtime seconds to complete.");

__DATA__
Do not remove. Makes sure flock() code above works as it should.
