#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use File::Find::utf8;
use File::Basename;
use Encode;
use utf8::all;

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
  $delete, $list, $generate, $empty_album, $parent_id, $disable_album, 
  $enable_album, $list_all, $help, $list_uuid, $aid, $list_images);

if (@ARGV > 0) {
  GetOptions(
    # searches in the path_original table
    's|search=s' => \$path_search,

    # the range of images, separated by comma
    'r|range=s' => \$img_range,

    # name of the album
    'a|album=s' => \$album_name,

    # use albumid to edit albums
    'aid=s' => \$aid,

    # description of album
    'd|desc|description=s' => \$album_description,

    # define category -- use default if not defined
    'c|cat|category=s' => \$category,

    # set a parent id for this album
    'p|parent=s' => \$parent_id,

    # disable all image ranges, or remove parent id
    'delete' => \$delete,

    # list latest 10 albums
    'list|print' => \$list,

    # list all albums
    'all' => \$list_all,

    # list images for specified album
    'listimages' => \$list_images,

    # list UUID-download-link
    'uuid' => \$list_uuid,

    # generate symlinks
    'gen|generate|cron' => \$generate,

    # make empty album
    'empty' => \$empty_album,

    # disable specified album
    'disable' => \$disable_album,

    # enable specified album
    'enable' => \$enable_album,

    # show help
    'help' => \$help,
  )
}

#########
######### TODO
#########
## - Disable/enable album from CLI
## - Make all images from /dates/ available as direct links ( '$URL/direct/md5sum_$imgname' or similar)
## 	- "Hidden" albums as well, using the same approach? ( '$URL/direct/album/md5sum_$album_name' or something)


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

    # Do this for each enabled range for this album
    $images = $imagelol->merge_image_ranges($images, $album, $album_name, $img_range, $category);
      
    # Add new range
    log_it("Adding range '$img_range [$category]' to album '$album_name'.");
    $imagelol->add_album_range($album->{albumid}, $img_range, $path_search, $category);
      
    # Warn if no images found
    unless((scalar keys %$images) > 0){
      error_log("No images found for the range '$img_range' with search '$path_search'.");
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
  delete_images($album_images, $albumid);
  
  # Lets add images still left in $new_images
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
  my $img_count;
  
  if((scalar keys %$albums) > 0){
    # We have albums -- go through them one-by-one, sorted by date added
    print("\n\n\n");

    if($list_uuid){
      printf("%-20s %-40s %-40s %-10s %-35s %-10s %-15s %-80s\n",
        "albumid",
        "name",
        "description",
        "parent",
        "added",
        "enabled",
        "# of images",
        "URL to download album");
    } else {
      printf("%-20s %-40s %-40s %-10s %-35s %-10s %-15s\n",
        "albumid",
        "name",
        "description",
        "parent",
        "added",
        "enabled",
        "# of images");
    }

    my $n = 180;
    $n = 260 if $list_uuid;
    print char_repeat($n, "-") . "\n";
    
    # only print last 10 albums by default
    my $album_count = 0;
    
    foreach my $albumid (sort { $albums->{$b}->{added} cmp $albums->{$a}->{added} } keys %$albums){
      unless($albums->{$albumid}->{parent}){
        unless($list_all){
          # count primary albums printed
          $album_count++;
          
          # exit if more than 10
          last if ($album_count > 10);
        }
        
        # Only do this to the primary albums (i.e. without a parent)
        print_album_line($albums, $albumid);
                
        # Let's find all the childs for this album
        print_album_childs($albums, $albumid);
        
        # Summarize total images
        $img_count += $albums->{$albumid}->{image_count};
      }
      # at this point we should be done
    }
    
    print char_repeat($n, "-") . "\n";
    printf ("%*s\n", $n, "Total number of images: $img_count");
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
  
  my $albumurl = $config{div}->{download_url} . $albums->{$albumid}->{uuid};
  
  # due to printf being sucky at unicode chars, we do it our own way
  my $string = space_pad(21, $newalbumid);
  $string .= space_pad(41, $albumname);
  $string .= space_pad(41, $description);
  $string .= space_pad(11, $parent);
  $string .= space_pad(36, $albums->{$albumid}->{added});
  $string .= space_pad(11, $albums->{$albumid}->{enabled});
  $string .= space_pad(16, $albums->{$albumid}->{image_count});
  $string .= space_pad(81, $albumurl) if $list_uuid;
  print "$string\n";
}

# List all albums
sub list_images{
  # Get all images for defined album
  my $album_info;

  if($aid && !$album_name){
    $album_info = $imagelol->get_album_by_id($aid);
  } elsif(!$aid && $album_name){
    $album_info = $imagelol->get_album($album_name);
  } else {
    exit error_log("Invalid options.");
  }

  unless($album_info){
    exit error_log("No album found.");
  }

  my $album_images = $imagelol->get_album_images($album_info->{albumid});

  if((scalar keys %$album_images) > 0){
    # We have images -- go through them one-by-one, sorted by date added
    print("\n\n\n");

    printf("Images for album '%s' (%s):\n\n",
      $album_info->{name},
      $album_info->{albumid}
    );

    printf("%-20s %-20s %-30s %-20s %-10s %-70s\n",
      "imageid",
      "name",
      "date",
      "category",
      "suffix",
      "path"
    );

    my $n = 170;
    print char_repeat($n, "-") . "\n";
    
    my $img_count = 0;

    foreach my $imageid (sort { $album_images->{$b}->{imagedate} cmp $album_images->{$a}->{imagedate} } keys %$album_images){
      printf("%-20s %-20s %-30s %-20s %-10s %-70s\n",
        $imageid,
        $album_images->{$imageid}->{imagename},
        $album_images->{$imageid}->{imagedate},
        $album_images->{$imageid}->{category},
        $album_images->{$imageid}->{suffix},
        $album_images->{$imageid}->{path_original}
      );

      $img_count++;
    }
    
    print char_repeat($n, "-") . "\n";
    printf ("%*s\n", $n, "Total number of images: $img_count");
    print("\n\n");
  } else {
    log_it("No images found...");
  }
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
    $symlink = decode('utf8', $symlink);
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
        if($albums->{$albumid}->{enabled}){
          # if enabled, add it + all of it's childs
        
          # summarize the album path
          my $new_album_path = $album_path . "/" . $albums->{$albumid}->{name};
        
          # add all images
          get_album_images($albumid, $new_album_path);
              
          # Look for more childs recursively
          get_album_childs($albums, $albumid, $new_album_path);
        }
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
  
  # Fix duplicate images here
  # We add a suffix for all duplicate images per album
  $album_images = fix_duplicate_image_names($album_images, $albumid);
    
  foreach my $imageid ( keys %$album_images ){
    # don't add disabled images
    next unless($album_images->{$imageid}->{enabled});

    # alter image src, so that it fits our www-scheme
    my $image_src = $album_images->{$imageid}->{path_preview};
    $image_src =~ s/^$config{path}->{preview_folder}//i; # remove the original prefix
    $image_src = $config{path}->{www_original} . $image_src; # add new prefix

    # alter image dst, so that it fits our www-scheme
    my $image_dst_path = $config{path}->{www_base}; # base prefix
    $image_dst_path .= "/" . $album_path; # album path

    # image name
    my ($image_name, $foo_path, $ext) = fileparse($album_images->{$imageid}->{path_preview}, '\..*');
    
    # handle duplicate images by using suffix
    if($album_images->{$imageid}->{suffix} > 1){
      # duplicate image, handle it!
      $image_name = $image_name . "_" . $album_images->{$imageid}->{suffix} . $ext;
    } else {
      # not a duplicate image, or duplicate image #1
      # in either of these cases, we keep the original image name
      $image_name = $image_name . $ext;
    }
    
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

# Fix duplicate image names
sub fix_duplicate_image_names{
  my ($album_images, $albumid) = @_;
  
  # We need to find all duplicate image names, and handle these specially
  # This is done to avoid duplicate image names in albums
    
  my %dup_images;
  
  foreach my $imageid ( keys %$album_images ){
    my $image_name = fileparse($album_images->{$imageid}->{path_preview}); # get only filename
    
    push(@{$dup_images{$image_name}}, $album_images->{$imageid});
  }
  
  foreach my $dup_image ( keys %dup_images ){
    my $dup_count = scalar(@{$dup_images{$dup_image}});
    unless($dup_count > 1){
      # we're only interested if we have more than 1 picture
      next;
    }
    
    # at this point we have duplicate images
    # we need to figure out if any of these already has a suffix
    # if not, we need to add one
    my @images = sort { $b->{suffix} <=> $a->{suffix} } @{$dup_images{$dup_image}};
    my $max_suffix = $images[0]->{suffix}; # get the highest suffix value
    $max_suffix = 0 unless(defined($max_suffix)); # set to 0 if no images has a suffix
    
    # since older imageid's already has been generated, we don't want them
    # to get a new name. by sorting the array we assume that the oldest image
    # is handled first (i.e. the image with the lowest imageid), hence get 
    # 'suffix = 1', and in turn keep it's name.
    foreach my $image ( sort { $a->{imageid} <=> $b->{imageid} } @{$dup_images{$dup_image}} ){
      next unless($image->{suffix} == 0); # already has a suffix defined
      
      $max_suffix++; # we increment by one
      
      debug_log("Setting suffix to '$max_suffix' for image '$image->{imageid}' in album '$albumid'.");
      $album_images->{$image->{imageid}}->{suffix} = $max_suffix;
      $imagelol->set_album_image_suffix($albumid, $image->{imageid}, $max_suffix);
    }
  }
  
  return $album_images;
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

if($help){
  # print help
  print qq(

    s|search=s            # searches in the path_original table
    r|range=s             # the range of images, separated by comma
    a|album=s             # name of the album
    aid=s                 # use albumid to edit albums
    d|desc|description=s  # description of album
    c|cat|category=s      # define category -- use default if not defined
    p|parent=s            # set a parent id for this album
    delete                # disable all image ranges, or remove parent id
    list|print            # list latest 10 albums
    all                   # list all albums
    listimages            # list images for specified album
    uuid                  # list UUID-download-link
    gen|generate|cron     # generate symlinks
    empty                 # make empty album
    disable               # disable specified album
    enable                # enable specified album
    help                  # show help


);

} else {
  # If $album_name, needs to be valid
  if($album_name){
    unless($album_name =~ m/^$config{regex}->{album_name}$/){
      exit error_log("Invalid album name.");
    }
  }
  
  # If $img_range, needs to be valid
  if($img_range){
    unless($img_range =~ m/^$config{regex}->{img_range}$/){
      exit error_log("Invalid image range.");
    }
  }

  # If albumid specified, check for valid input
  if($aid){
    unless($aid =~ /^\d+$/){
      exit error_log("Invalid albumid.");
    }
  }

  # If we should list albums, images, or make symlinks, we do that here
  if($list || $generate || $list_images){
    if($list && !$generate && !$list_images){
      list_albums();
    } elsif(!$list && $generate && !$list_images){
      generate_symlinks();
    } elsif(!$list && !$generate && $list_images){
      if($album_name || $aid){
        list_images();
      } else {
        exit error_log("No album defined.");
      }
    } else {
      exit error_log("Invalid options.");
    }
  } else {
    # Unless category defined, use default
    unless($category){
      $category = $config{div}->{default_category};
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

    # Set $album_name based on albumid (useful when editing albums)
    if($aid){
      my $albuminfo = $imagelol->get_album_by_id($aid);

      if($albuminfo){
        $album_name = $albuminfo->{name};
      } else {
        exit error_log("No album with that albumid.");
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
    
    # Only delete image-ranges
    if(($album_name && $delete) && !$path_search && !$img_range && !$album_description){
      my $album = $imagelol->get_album($album_name);
      if($album){
        # We disable all previous ranges, and update with current images
        $imagelol->disable_album_ranges($album->{albumid});
        log_it("All previous ranges for album '$album_name' has now been disabled.");
        exit 1;
      } else {
        # Not a valid album
        exit error_log("Album doesn't exist. Try again.");
      }
    }
    
    # At this point, we don't need $delete anymore
    if($delete){
      exit error_log("Can't use -delete in this combination.");
    }
  
    # Set default search-path (current year + month)
    unless($path_search){
      $path_search = $imagelol->date_string_ym();
    }

    # Need at least these three if we are to do anything more
    unless($path_search && $img_range && $album_name){
      exit error_log("Need to fill out all the required parameters.");
    }

    # At this point we should have a valid starting point
    fix_album();
  }
}

$imagelol->disconnect();

unless($list || $generate || $help || $list_images ){
  # How long did we run
  my $runtime = time() - $time_start;
  log_it("Took $runtime seconds to complete.");
}

__DATA__
Do not remove. Makes sure flock() code above works as it should.
