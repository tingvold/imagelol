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
	)
}

#########
######### TODO
#########
## - List albums (in hiarchy, so nested albums are displayed under each other)
## - Adding albums without images (to use for nested albums/sub-albums)
## 	- Use recursion to build the trees/folder-structure for the albums/sub-albums
## - 

# Add images to album -- create album if needed
sub fix_album{
	my $images = $imagelol->get_image_range($img_range, $path_search);
	
	if($images){
		# We have some images. Act upon them. A few assumptions have been made;
		#	- A new $img_range will overwrite any old ones. The history is stored, though.
		#	  This way, if one by accident add a new range that is not correct, one can find
		#	  the previous range, and restore it.
		#	- 
		
		# First we check if album exists
		my $album = $imagelol->get_album($album_name);
		if($album){
			# We overwrite the $img_range
			$imagelol->set_imgrange($album->{albumid}, $img_range);
			
			# We add entries that isn't present from before
			# We remove entries that are no longer present
			add_delete_albumentries($images, $album->{albumid});
		} else {
			# We create it from scratch
			add_new_album($images, $album_name, $img_range);
		}
	} else {
		error_log("No images found for the range '$img_range' with search '$path_search'.");
	}
}

# Add or delete images from an album
sub add_delete_albumentries{
	# 1) Fetch all images in album
	# 2) Iterate through $images, and delete from hash all entries that is present both places
	# 3) The images left in album, should be deleted
	# 4) The images left in $images, should be added

}

# Add a new album
sub add_new_album{
	# 1) Add a new album
	# 2) Set the $img_range for that album
	# 3) Add all images to the album
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


# If $img_range, needs to be valid
if($img_range){
	unless($img_range =~ m/^$config{regex}->{img_range}$/){
		return error_log("Invalid image range.");
	}
}

# If $album_name, needs to be valid
if($album_name){
	unless($album_name =~ m/^$config{regex}->{album_name}$/){
		return error_log("Invalid album name.");
	}
}

# Update album description only
if(($album_name && $album_description) && !$path_search && !$img_range){
	update_album_description();
}

# Need at least these three if we are to do anything more
unless($path_search && $img_range && $album_name){
	return error_log("Need to fill out all the required parameters.");
}

# At this point we should have a valid starting point
fix_album();


$imagelol->disconnect();

# How long did we run
my $runtime = time() - $time_start;
log_it("Took $runtime seconds to complete.");

__DATA__
Do not remove. Makes sure flock() code above works as it should.
