#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Getopt::Long;
use File::Find;
use Data::Dumper;

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
my ($path_search, $img_range, $album_name, $album_description, $delete_range);
if (@ARGV > 0) {
	GetOptions(
	'search=s'		=> \$path_search,
	'range=s'		=> \$img_range,
	'album=s'		=> \$album_name,
	'desc|description=s'	=> \$album_description,
	'delete'		=> \$delete_range,
	)
}

#########
######### TODO
#########
## - List albums (in hiarchy, so nested albums are displayed under each other)
## - Adding albums without images (to use for nested albums/sub-albums)
## 	- Use recursion to build the trees/folder-structure for the albums/sub-albums

# Add images to album -- create album if needed
sub fix_album{
	my $images = $imagelol->get_image_range($img_range, $path_search);
	
	if((scalar keys %$images) > 0){
		# We have some images. Act upon them. A few assumptions have been made;
		#	- A new $img_range will overwrite any old ones. The history is stored, though.
		#	  This way, if one by accident add a new range that is not correct, one can find
		#	  the previous range, and restore it.
		#	- 
		
		# First we check if album exists
		my $album = $imagelol->get_album($album_name);
		if($album){
			# Default is to add the range to current ranges
			# However, if we want to delete (i.e. overwrite) the current images in an
			# album with a new range, we can use this
			if($delete_range){
				# We disable all previous ranges, and update with current images
				$imagelol->disable_album_ranges($album->{albumid});
				log_it("Since deletion was used, all previous ranges for album '$album_name' has now been disabled.");
			} else {
				# Do this for each enabled range for this album
				my $enabled_ranges = $imagelol->get_album_ranges($album->{albumid});
				
				foreach my $rangeid ( keys %$enabled_ranges ){
					my $old_range = $enabled_ranges->{$rangeid}->{imagerange};
					my $old_search = $enabled_ranges->{$rangeid}->{path_search};
					
					# Get old images
					my $old_images = $imagelol->get_image_range($old_range, $old_search);
					
					if((scalar keys %$old_images) > 0){
						# We got old images, lets merge them
						log_it("Merging image-range '$old_range' with provided range ($img_range).");
						$images = { %$images, %$old_images };
					} else {
						error_log("No images found for the album '$album_name' with range '$old_range' and search '$old_search'.");
					}
				}
			}
			
			# Add new range
			log_it("Adding range '$img_range' to album '$album_name'.");
			$imagelol->add_album_range($album->{albumid}, $img_range, $path_search);
						
			# We add entries that isn't present from before
			# We remove entries that are no longer present
			add_delete_albumentries($images, $album->{albumid});
		} else {
			# We create it from scratch
			add_new_album($images);
		}
	} else {
		error_log("No images found for the range '$img_range' with search '$path_search'.");
	}
}

# Add or delete images from an album
sub add_delete_albumentries{
	my ($new_images, $albumid) = @_;
	
	my $album_images = $imagelol->get_album_images($albumid);
	
	# We iterate through $new_images, as this is the authorative source
	foreach my $imageid ( keys %$new_images ){
		# Since we search for images using both $search_path and $img_range
		# we should assume that the images we have are unique, in such a way
		# that we can compare the imageid directly, without having to check
		# the image path or similar.
		
		if($album_images->{$imageid}){
			# Entry exists in both new and old
			# Delete from both places
			delete($new_images->{$imageid});
			delete($album_images->{$imageid});
		}
	}
	
	# Lets delete images still left in $album_images
	log_it("Deleting images from album '$album_name'.");
	delete_images($album_images, $albumid);
	
	# Lets add images still left in $new_images
	log_it("Adding images to album '$album_name'.");
	add_images($new_images, $albumid);
}

# Delete images from album
sub delete_images{
	my ($images, $albumid) = @_;
	
	foreach my $imageid ( keys %$images ){
		# Delete image $imageid from album $albumid
		$imagelol->delete_image($imageid, $albumid);
		debug_log("Deleted imageid $imageid from albumid $albumid.");
	}
}

# Add images to album
sub add_images{
	my ($images, $albumid) = @_;
	
	foreach my $imageid ( keys %$images ){
		# Add image $imageid to album $albumid
		$imagelol->add_image($imageid, $albumid);
		debug_log("Added imageid $imageid to albumid $albumid.");
	}
}

# Add a new album
sub add_new_album{
	my $images = shift;
	$album_description = '' unless $album_description; # done to avoid uninitialized-error

	# Create album -- albumid of created album is returned
	my $albumid = $imagelol->add_album($album_name, $album_description);
	log_it("Added new album ($album_name), that got albumid $albumid.");
	
	# Add image range
	log_it("Adding range '$img_range' to album '$album_name'.");
	$imagelol->add_album_range($albumid, $img_range, $path_search);
	
	# Add all images in $img_range to that album
	log_it("Adding images to album '$album_name'.");
	add_images($images, $albumid);
}

# Update description on album
sub update_album_description{
	my $album = $imagelol->get_album($album_name);
	if($album){
		# Album exists
		$imagelol->set_album_description($album->{albumid}, $album_description);
	} else {
		# Album doesn't exist
		error_log("No album found matching that name ($album_name).");
	}
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
		exit error_log("Invalid image range.");
	}
}

# If $album_name, needs to be valid
if($album_name){
	unless($album_name =~ m/^$config{regex}->{album_name}$/){
		exit error_log("Invalid album name.");
	}
}

# Update album description only
if(($album_name && $album_description) && !$path_search && !$img_range && !$delete_range){
	update_album_description();
	log_it("Set description for album '$album_name' to '$album_description'.");
	exit 0;
}

# Need at least these three if we are to do anything more
unless($path_search && $img_range && $album_name){
	exit error_log("Need to fill out all the required parameters.");
}

# At this point we should have a valid starting point
fix_album();

$imagelol->disconnect();

# How long did we run
my $runtime = time() - $time_start;
log_it("Took $runtime seconds to complete.");

__DATA__
Do not remove. Makes sure flock() code above works as it should.
