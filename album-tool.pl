#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Getopt::Long;
use File::Find;
use File::Basename;
use Encode;

# Load imagelol
my $imagelol_dir;
BEGIN { $imagelol_dir = "/srv/bilder/imagelol"; }
use lib $imagelol_dir;
use imagelol;
my $imagelol = imagelol->new();
my %config = $imagelol->get_config();

# Log
sub log_it{
	$imagelol->log_it("album-tool", "@_");
}

# Logs debug-stuff if debug has been turned on
sub debug_log{
	$imagelol->debug_log("album-tool", "@_");
}

# Logs error-stuff
sub error_log{
	$imagelol->error_log("album-tool", "@_");
	return 0;
}

# All images from DB
my %images_from_db;

# Get options
my (	$path_search, $img_range, $album_name, $album_description, $category,
	$delete, $list, $generate, $empty_album, $parent_id, $disable_album);

if (@ARGV > 0) {
	GetOptions(
	's|search=s'		=> \$path_search,	# searches in the path_original table
	'r|range=s'		=> \$img_range,		# the range of images, separated by comma
	'a|album=s'		=> \$album_name,	# name of the album
	'd|desc|description=s'	=> \$album_description,	# description of album
	'c|cat|category=s'	=> \$category,		# define category -- use default if not defined
	'p|parent=s'		=> \$parent_id,		# set a parent id for this album
	'delete'		=> \$delete,		# disable all image ranges, or remove parent id
	'list|print'		=> \$list,		# list all albums
	'gen|generate|cron'	=> \$generate,		# generate symlinks
	'empty'			=> \$empty_album,	# make empty album
	'disable'		=> \$disable_album,	# disable specified album
	)
}

#########
######### TODO
#########
## - List detailed info about specific album (i.e. all active image-ranges + all images + number of images)
## - Disable/enable album from CLI


# Add images to album -- create album if needed
sub fix_album{
	# Get images
	my $images = $imagelol->get_image_range($img_range, $path_search, $category);
	debug_log("$img_range, $path_search, $category");
	
	# Check if album exists
	my $album = $imagelol->get_album($album_name);
	if($album){
		# Default is to add the range to current ranges
		# However, if we want to delete (i.e. overwrite) the current images in an
		# album with a new range, we can use this

		if($delete){
			# We disable all previous ranges, and update with current images
			$imagelol->disable_album_ranges($album->{albumid});
			log_it("Since deletion was used, all previous ranges for album '$album_name' has now been disabled.");
		} else {
			# Do this for each enabled range for this album
			my $enabled_ranges = $imagelol->get_album_ranges($album->{albumid});
			
			foreach my $rangeid ( keys %$enabled_ranges ){
				my $old_range = $enabled_ranges->{$rangeid}->{imagerange};
				my $old_search = $enabled_ranges->{$rangeid}->{path_search};
				my $old_category = $enabled_ranges->{$rangeid}->{category};
									
				# Get old images
				my $old_images = $imagelol->get_image_range($old_range, $old_search, $old_category);
				
				if((scalar keys %$old_images) > 0){
					# We got old images, lets merge them
					log_it("Merging image-range '$old_range [$old_category]' with provided range ($img_range [$category]).");
					$images = { %$images, %$old_images };
				} else {
					error_log("No images found for the album '$album_name' with range '$old_range [$old_category]' and search '$old_search'.");
				}
			}
			
			# Add new range, but not if we're deleting
			log_it("Adding range '$img_range [$category]' to album '$album_name'.");
			$imagelol->add_album_range($album->{albumid}, $img_range, $path_search, $category);
			
			# Warn if no images found
			unless((scalar keys %$images) > 0){
				error_log("No images found for the range '$img_range' with search '$path_search'.");
			}
		}
			
		# We add entries that isn't present from before
		# We remove entries that are no longer present
		add_delete_albumentries($images, $album->{albumid});
	} else {
		# We create it from scratch
		add_new_album($images);
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
		$imagelol->delete_album_image($imageid, $albumid);
		debug_log("Deleted imageid $imageid from albumid $albumid.");
	}
}

# Add images to album
sub add_images{
	my ($images, $albumid) = @_;
	
	foreach my $imageid ( keys %$images ){
		# Add image $imageid to album $albumid
		$imagelol->add_album_image($imageid, $albumid);
		debug_log("Added imageid $imageid to albumid $albumid.");
	}
}

# Add a new album
sub add_new_album{
	my $images = shift;
	$album_description = '' unless $album_description; # done to avoid uninitialized-error

	# Create album -- albumid of created album is returned
	my $albumid = $imagelol->add_album($album_name, $album_description, $parent_id);
	
	if($empty_album){
		# empty album is to be added, do nothing more
		log_it("Added new empty album ($album_name), that got albumid $albumid.");
	} else {
		log_it("Added new album ($album_name), that got albumid $albumid.");
		
		# Add image range
		log_it("Adding range '$img_range' to album '$album_name'.");
		$imagelol->add_album_range($albumid, $img_range, $path_search, $category);

		# Add all images in $img_range to that album
		log_it("Adding images to album '$album_name'.");
		add_images($images, $albumid);
	}
}

# Update description on album
sub update_album_description{
	my $album = $imagelol->get_album($album_name);
	if($album){
		# Album exists
		$imagelol->set_album_description($album->{albumid}, $album_description);
		log_it("Set description for album '$album_name' to '$album_description'.");
	} else {
		# Album doesn't exist
		error_log("No album found matching that name ($album_name).");
	}
}

# Update $parent_id on album
sub update_album_parent{
	my $album = $imagelol->get_album($album_name);
	if($album){
		# Album exists
		my $parent_id_print = $parent_id;
		if($delete){
			# We want to remove parent id from current album
			# Set $parent_id to 'NULL'.
			$parent_id = '';
			$parent_id_print = 'NULL';
		}
		
		$imagelol->set_album_parent($album->{albumid}, $parent_id);
		log_it("Set parent id for album '$album_name' to '$parent_id_print'.");
	} else {
		# Album doesn't exist
		error_log("No album found matching that name ($album_name).");
	}
}

# Add empty album
sub add_empty_album{
	my $album = $imagelol->get_album($album_name);
	if($album){
		# Album exists
		error_log("Trying to add a new album, but album with name '$album_name' already exists.");
	} else {
		# Album doesn't exist
		add_new_album();
	}
}

# Return X number of a specific character
sub char_repeat{
	my $n = shift;
	my $char = shift;

	(my $line = "") =~ s/^(.*)/"$char" x $n . $1/e;
	
	return $line;
}

# return space-padded string with length n
sub space_pad{
	my $n = shift;
	my $string = shift;

	$string .= char_repeat(($n - length(Encode::decode_utf8($string))), " ");
	
	return $string;
}

# List all albums
sub list_albums{
	# Get all albums
	my $albums = $imagelol->get_albums();
	
	if((scalar keys %$albums) > 0){
		# We have albums -- go through them one-by-one, sorted by date added
		print("\n\n\n");
		printf("%-20s %-40s %-40s %-10s %-35s %-10s %-10s\n", "albumid", "name", "description", "parent", "added", "enabled", "# of images");

		my $n = 165;
		print char_repeat($n, "-") . "\n";
		
		foreach my $albumid (sort { $albums->{$b}->{added} cmp $albums->{$a}->{added} } keys %$albums){
			unless($albums->{$albumid}->{parent}){
				# Only do this to the primary albums (i.e. without a parent)
				print_album_line($albums, $albumid);
								
				# Let's find all the childs for this album
				print_album_childs($albums, $albumid);
			}
			# at this point we should be done
		}
		
		print char_repeat($n, "-") . "\n";
		print("\n\n");
	} else {
		log_it("No albums found...");
	}
}

# Print childs for a specific albumid
sub print_album_childs{
	my ($albums, $parent_albumid, $level) = @_;
	
	if(defined($level)){
		$level++;
	} else {
		$level = 1;
	}

	foreach my $albumid (sort { $albums->{$b}->{added} cmp $albums->{$a}->{added} } keys %$albums){
		if($albums->{$albumid}->{parent}){
			# we have an album with a parent defined
			if($albums->{$albumid}->{parent} == $parent_albumid){
				# we have a child for the parent album
				# print it + all of it's childs
				print_album_line($albums, $albumid, $level);
				
				# Look for more childs recursively
				print_album_childs($albums, $albumid, $level);
			}
		}
	}
	
	return 1; # stop recursion/subroutine, not really needed
}

# Print single album-line
sub print_album_line{
	my ($albums, $albumid, $level) = @_;
	
	# make short names, fitting the printf lengths
	my $albumname = $albums->{$albumid}->{name};
	if(length($albumname) > 35){
		$albumname = substr($albumname, 0, 32);
		$albumname .= " [...]";
	}
	
	my $description = $albums->{$albumid}->{description};
	if(length($description) > 35){
		$description = substr($description, 0, 32);
		$description .= " [...]";
	}
	
	my $parent = $albums->{$albumid}->{parent};
	my $level_string = '';
	
	if($parent){
		$level_string = char_repeat($level, '>') . " ";
	} else {
		$parent = "-";
	}
	
	my $newalbumid = $level_string . $albumid;
	
	# due to printf being sucky at unicode chars, we do it our own way
	my $string = space_pad(21, $newalbumid);
	$string .= space_pad(41, $albumname);
	$string .= space_pad(41, $description);
	$string .= space_pad(11, $parent);
	$string .= space_pad(36, $albums->{$albumid}->{added});
	$string .= space_pad(11, $albums->{$albumid}->{enabled});
	$string .= space_pad(11, $albums->{$albumid}->{image_count});
	print "$string\n";
}

# Generate all the symlinks
sub generate_symlinks{
	# General thought here is to iterate through all the albums, generate the
	# symlinks needed (but don't act on them). Then we iterate through all existing
	# symlinks. We then compare the two, and delete/add at the end.

	# Get all albums
	my $albums = $imagelol->get_albums();
	
	if((scalar keys %$albums) > 0){
		# We have albums -- go through them one-by-one
		
		foreach my $albumid ( keys %$albums ){
			if($albums->{$albumid}->{enabled}){
				# only add enabled albums
				unless($albums->{$albumid}->{parent}){
					# album without parent defined -- these are our root albums
				
					# add album-info to hash
					$images_from_db{$albumid}{albumname} = $albums->{$albumid}->{name};
				
					# add all images
					get_album_images($albumid, $albums->{$albumid}->{name});
				
					# add all childs recursively
					get_album_childs($albums, $albumid, $albums->{$albumid}->{name});
				}
			}
		}
	} else {
		exit error_log("No albums found...");
	}
	
	# All images on filesystem
	my %images_on_file;
	
	# Add images on filesystem to the hash
	foreach my $symlink ($imagelol->system_find_symlinks($config{path}->{www_base})){
		chomp($symlink);
		$images_on_file{$symlink} = 1;
	}
	
	# Compare the two -- database is authorative
	foreach my $albumid ( keys %images_from_db ){
		# compare each image
		foreach my $albumimage ( keys %{$images_from_db{$albumid}->{images}} ){
			if($images_on_file{$albumimage}){
				# Entry exists in both DB and filesystem
				# Delete from both places
				delete($images_from_db{$albumid}{images}{$albumimage});
				delete($images_on_file{$albumimage});
			}
		}
	}
	
	# At this point we should have two hashes; one with
	# all images currentl in the DB, that is not present
	# on the filesystem, and another with the images present
	# on the filesystem, but no on the DB.
	
	# Delete symlinks from filesystem
	delete_symlinks(\%images_on_file);
	
	# Add images from database
	add_symlinks(\%images_from_db);
}

# Subroutine to add all child albums to hash
sub get_album_childs{
	my ($albums, $parent_albumid, $album_path) = @_;

	foreach my $albumid ( keys %$albums ){
		if($albums->{$albumid}->{parent}){
			# we have an album with a parent defined
			if($albums->{$albumid}->{parent} == $parent_albumid){
				# we have a child for the parent album
				# add it + all of it's childs
				
				# summarize the album path
				my $new_album_path = $album_path . "/" . $albums->{$albumid}->{name};
				
				# add all images
				get_album_images($albumid, $new_album_path);
							
				# Look for more childs recursively
				get_album_childs($albums, $albumid, $new_album_path);
			}
		}
	}	
	return 1; # stop recursion/subroutine, not really needed
}


# Subroutine to add album images to hash
sub get_album_images{
	my ($albumid, $album_path) = @_;

	# find album images
	my $album_images = $imagelol->get_album_images($albumid);

	foreach my $imageid ( keys %$album_images ){
		# alter image src, so that it fits our www-scheme
		my $image_src = $album_images->{$imageid}->{path_preview};
		$image_src =~ s/^$config{path}->{preview_folder}//i; # remove the original prefix
		$image_src = $config{path}->{www_original} . $image_src; # add new prefix

		# alter image dst, so that it fits our www-scheme
		my $image_dst_path = $config{path}->{www_base}; # base prefix
		$image_dst_path .= "/" . $album_path; # album path

		# image name
		my $image_name = basename($album_images->{$imageid}->{path_preview}); # get only filename

		# full path
		my $image_dst = $image_dst_path . "/" . $image_name;

		my %image = (
			image_src => $image_src,
			image_dst_path => $image_dst_path,
			image_name => $image_name,
		);

		# add to hash
		$images_from_db{$albumid}{images}{$image_dst} = \%image;				
	}
}

# Delete all symlinks from filesystem
sub delete_symlinks{
	my $files = shift;
	
	foreach my $file ( keys %$files ){
		if($imagelol->system_rm($file)){
			debug_log("Successfully removed symlink to '$file'.");
		} else {
			return error_log("Could not remove symlink '$file'.");
		}
	}
}

# Add all symlinks from DB
sub add_symlinks{
	my $files = shift;
	
	foreach my $albumid ( keys %$files ){
		# compare each image
		foreach my $albumimage ( keys %{$files->{$albumid}{images}} ){
			my $dst_dir = $files->{$albumid}{images}{$albumimage}{image_dst_path};
			my $file_src = $files->{$albumid}{images}{$albumimage}{image_src};
			
			# Directory
			unless (-d "$dst_dir"){
				# create directory
				debug_log("Creating directory '$dst_dir'.");
				$imagelol->system_mkdir($dst_dir)
					or return error_log("Could not create directory '$dst_dir'.");
			}
			
			# Symlink
			if(-e "$albumimage"){
				return error_log("Image destination '$albumimage' exists. Should not happen.");
			} else {
				# make symlink
				debug_log("Creating symlink from  '$file_src' to '$albumimage'.");
				$imagelol->system_ln($file_src, $albumimage);
			}

			
		}
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

# If we should list albums, or make symlinks, we do that here
if($list || $generate){
	if($list){
		list_albums();
	}
	
	if($generate){
		generate_symlinks();
	}
} else {
	# Unless category defined, use default
	unless($category){
		$category = $config{div}->{default_category};
	}

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
	
	# If $parent_id, needs to be valid + exist
	if(defined($parent_id)){
		if($parent_id =~ m/^$config{regex}->{parent_id}$/){
			# check if album exists
			unless($imagelol->album_exists($parent_id)){
				# album doesn't exist
				if($delete){
					# don't warn if we are to delete parent id
					if($empty_album){
						# but warn if we try to create empty album at the same time
						exit error_log("Can't add empty album when '-delete' parameter specified.");
					}
				} else {
					exit error_log("Parent id doesn't exist.");
				}
			}
		} else {
			exit error_log("Invalid parent id.");
		}
	}
	
	# If empty album is to be added
	if($empty_album){
		if($album_name){
			# only do this if we actually have $album_name
			add_empty_album();
			exit 1;
		} else {			
			exit error_log("Need to fill out all the required parameters.");
		}
	}

	# Update album description only
	if(($album_name && $album_description) && !$path_search && !$img_range && !$delete){
		update_album_description();
		exit 1;
	}
	
	# Update parent_id only
	if(($album_name && defined($parent_id)) && !$path_search && !$img_range && !$album_description){
		update_album_parent();
		exit 1;
	}

	# Need at least these three if we are to do anything more
	unless($path_search && $img_range && $album_name){
		exit error_log("Need to fill out all the required parameters.");
	}

	# At this point we should have a valid starting point
	fix_album();
}

$imagelol->disconnect();

unless($list || $generate){
	# How long did we run
	my $runtime = time() - $time_start;
	log_it("Took $runtime seconds to complete.");
}

__DATA__
Do not remove. Makes sure flock() code above works as it should.
