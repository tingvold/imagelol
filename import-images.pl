#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Getopt::Long;
use File::Find;
use Image::ExifTool;
use File::stat;
use threads;
use threads::shared;
use Thread::Queue;

# Load imagelol
my $imagelol_dir;
BEGIN { $imagelol_dir = "/srv/bilder/imagelol"; }
use lib $imagelol_dir;
use imagelol;
my $imagelol = imagelol->new();
my %config = $imagelol->get_config();

# Variables
my $max_threads = 7;			# Max threads to use
my $imageq = Thread::Queue->new(); 	# Queue to put image files in
my %images : shared;			# Images to add to DB

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
	return 0;
}

# Get options
my ($src_dir, $dst_dir, $category, $desc, $force_copy, $date_override);
if (@ARGV > 0) {
	GetOptions(
	's|src|source=s'	=> \$src_dir,		# the source of the images to be imported
	'c|cat|category=s'	=> \$category,		# category to put the images in
	'd|desc|description=s'	=> \$desc,		# add comment/description to imported images
	'f|force'		=> \$force_copy,	# force copy/update, even if destination exist
	'date=s'		=> \$date_override,	# override date of files being added
	)
}

# Set paths from config, unless provided as parameter
if ($category){
	die error_log("Invalid category. Only numbers and letters allowed.") unless ($category =~ m/^[a-zA-Z0-9]+$/);
}

# Check if valid date is entered; 2012-03-04
if ($date_override){
	unless ($date_override =~ m/^[0-9]{4}\:[0-9]{2}\:[0-9]{2}$/){
		die error_log("Invalid date entered ($date_override). Should look like 'YYYY:MM:DD'. Try again.");
	}
}

$category = $config{div}->{default_category} unless $category;
$src_dir = $config{path}->{import_folder} unless $src_dir;
$dst_dir = $config{path}->{original_folder} . "/" . $category;

die error_log("Source directory doesn't exist. Exiting.") unless (-d $src_dir);

# Find images
sub find_images{
	# Find and import all images
	find(\&image_queue, $src_dir);
}

# Add images to queue
sub image_queue{
	my $org_src = "$File::Find::name";
	my $filename = "$_";
	
	my $pretty_filename = $filename;
	$pretty_filename =~ s/[^\w\_\.]/_/g;	# remove all non-alphanumeric, replace with lowerscore
	$pretty_filename =~ s/\_+/_/g;		# replace all double-lowerscores with a single lowerscore
	$pretty_filename =~ s/([^\w]){2,}/$1/g;	# replace all double-or-more non-alphanumeric with a single char
	
	my %image = (
		org_src => $org_src,
		filename => $filename,
		pretty_filename => $pretty_filename,
	);
	
	# Add image to queue
	unless (-d "$org_src"){
		# don't do anything with folders
		$imageq->enqueue(\%image);
	}
}

# Process single image
sub process_image{
	my $image = shift;
	
	if (	$image->{filename} =~ m/^.+\.($config{div}->{image_filenames})$/i ||
		$image->{filename} =~ m/^.+\.($config{div}->{movie_filenames})$/i ||
		$image->{filename} =~ m/^.+\.($config{div}->{psd_filenames})$/i){
		# We have a image (or, at least a filename that matches the image_filenames variable)
		
		log_it("Processing image $image->{filename}...");
		
		# Is this a RAW or PSD image? (affects what we do with preview, etc)
		my ($is_raw, $is_psd) = (0, 0);
		$is_raw = 1 if ($image->{filename} =~ m/^.+\.($config{div}->{raw_image})$/i);
		$is_psd = 1 if ($image->{filename} =~ m/^.+\.($config{div}->{psd_filenames})$/i);

		# We need to figure out the date the picture was taken
		# First we try to use EXIF, and if that fails, we use the 'file created'
		my $exif_tags = Image::ExifTool::ImageInfo(	$image->{org_src}, { PrintConv => 0 },
								'DateTimeOriginal', 'PreviewImage', 'Orientation',
								'FileType', 'FileModifyDate' );
		return error_log("EXIF failed: $exif_tags->{Error}") if $exif_tags->{'Error'};

		my ($date, $time, $full_date);
		if (defined($exif_tags->{'DateTimeOriginal'})){
			# We have a value
			# 'DateTimeOriginal' => '2012:12:31 17:50:01',

			if ($exif_tags->{'DateTimeOriginal'} =~ m/^[0-9]{4}\:[0-9]{2}\:[0-9]{2}\s+/){
				($date, $time) = (split(' ', $exif_tags->{'DateTimeOriginal'}));
				$date = $date_override if $date_override; # override if specified
				($full_date = $date) =~ s/\:/-/g;
				$full_date .= " " . $time;
			}
		} elsif (defined($exif_tags->{'FileModifyDate'})){
			# We have a value
			# 'FileModifyDate' => '2013:08:03 21:54:09+02:00',
			
			if ($exif_tags->{'FileModifyDate'} =~ m/^[0-9]{4}\:[0-9]{2}\:[0-9]{2}\s+/){
				($date, $time) = (split(' ', $exif_tags->{'FileModifyDate'}));
				$date = $date_override if $date_override; # override if specified
				($full_date = $date) =~ s/\:/-/g;
				$full_date .= " " . $time;
			}
		}

		unless ($date){
			# No (valid) date was found with EXIF
			# Using 'file created'

			# Last access:		stat($_)->atime
			# Last modify:		stat($_)->mtime
			# File creation:	stat($_)->ctime

			# Use YYYY:MM:DD, so that it's the same output as EXIF
			$date = POSIX::strftime("%Y:%m:%d", localtime(stat($image->{org_src})->ctime()));
			$date = $date_override if $date_override; # override if specified
			$full_date = POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime(stat($image->{org_src})->ctime()));
		}

		# At this point it should be safe to assume that $date
		# has a value, and that it looks like YYYY:MM:DD
		my ($year, $month, $day) = split(':', $date);

		# We now know the dates when the file was created
		# Check if directory exists, if not, create it
		my $image_dst_dir = $dst_dir . "/" . $year . "/" . $month . "/" . $day;
		unless (-d $image_dst_dir){
			# create directory
			debug_log("Creating directory '$image_dst_dir'.");
			$imagelol->system_mkdir($image_dst_dir)
				or return error_log("Could not create directory '$image_dst_dir'.");
		}

		# Check if destination image exists
		my $image_dst_file = $image_dst_dir . "/" . $image->{pretty_filename};
		unless ($force_copy){
			if (-e $image_dst_file){
				return error_log("Destination file ($image_dst_file) exists. Aborting.");
			}
		}

		# Copy image
		debug_log("Copying image '$image->{org_src}' to '$image_dst_file'.");
		$imagelol->copy_stuff($image->{org_src}, $image_dst_file)
			or return error_log("Could not copy image '$image->{org_src}' to '$image_dst_file'.");

		# If movie, we've done enough
		if ($image->{filename} =~ m/^.+\.($config{div}->{movie_filenames})$/i){
			if (-e $image->{org_src}){
				# The file actually exists, lets delete it.
				$imagelol->system_rm($image->{org_src})
					or return error_log("Could not delete movie '$image->{org_src}'.");
			}
			return 1; # return gracefully -- this is not a fail
		}

		# Extract preview
		# Save full version + resized version
		my $jpg_from_raw;
		if ($is_raw){
			debug_log("Extracting preview from RAW file.");

			# Exit if error
			unless (defined($exif_tags->{'PreviewImage'})){
				return error_log("No preview found.");
			}

			# Fetch JPG
			$jpg_from_raw = $exif_tags->{'PreviewImage'};
			$jpg_from_raw = $$jpg_from_raw if ref($jpg_from_raw);
		}
		
		# Create dir
		my $preview_dst_dir = $config{path}->{preview_folder} . "/" . $category . "/" . $year . "/" . $month . "/" . $day;

		unless (-d $preview_dst_dir){
			# create directory
			debug_log("Creating directory '$preview_dst_dir'.");
			$imagelol->system_mkdir($preview_dst_dir) 
				or return error_log("Could not create directory image '$preview_dst_dir'.");
		}

		# Make filename of preview
		# Here we try to fetch the info via EXIF-tags
		# Then we try to use the filename of the original file
		(my $jpg_filename = $image->{pretty_filename}) =~ s/\.[^.]+$//;
		
		if($is_raw || $is_psd){
			# These are converted to .jpg, so no more checks
			$jpg_filename .= ".jpg";
		} else {
			# Other files
			if (defined($exif_tags->{'FileType'})){
				# we have a filetype -- let's use that
				my $filetype = lc($exif_tags->{'FileType'});
				$filetype = "jpg" if($filetype =~ m/jpeg/i);
				$jpg_filename .= ".$filetype";
			} else {
				# no value -- assume .jpg
				$jpg_filename .= ".jpg";
			}
		}	
			
		my $jpg_dst = $preview_dst_dir . "/" . $jpg_filename;

		# Copy preview
		if ($is_raw){
			# Extract preview from RAW file
			my $JPG_FILE;
			open(JPG_FILE,">$jpg_dst") or return error_log("Error creating '$jpg_dst'.");
			binmode(JPG_FILE);
			my $err;
			print JPG_FILE $jpg_from_raw or $err = 1;
			close(JPG_FILE) or $err = 1;
			if ($err) {
				unlink $jpg_dst; # remove the bad file
				return error_log("Could not copy preview image '$jpg_dst'. Aborting.");
			}
		} elsif ($is_psd){
			# PSD
			$imagelol->convert_psd($image->{org_src}, $jpg_dst)
				or return error_log("Could not convert PSD image '$image->{org_src}' to '$jpg_dst'.");
		} else {
			# Copy normally, as source is non-RAW
			$imagelol->copy_stuff($image->{org_src}, $jpg_dst)
				or return error_log("Could not copy image '$image->{org_src}' to '$jpg_dst'.");
		}

		# Copy EXIF-data from source, into preview
		$imagelol->copy_exif($image->{org_src}, $jpg_dst)
			or return error_log("Could not copy EXIF data from '$image->{org_src}' to '$jpg_dst'.");
			
		# Copy timestamp from source, into preview
		# This is used by gallery if no EXIF-data exists
		$imagelol->copy_timestamp($image->{org_src}, $jpg_dst)
			or return error_log("Could not copy timestamp from '$image->{org_src}' to '$jpg_dst'.");

		# Rotate full preview (if needed)
		# http://sylvana.net/jpegcrop/exif_orientation.html
		# http://www.impulseadventure.com/photo/exif-orientation.html
		# We do rotation unless 'orientation == 1'	
		my $rotate = 1;
		if (defined($exif_tags->{'Orientation'})){
			$rotate = 0 if ($exif_tags->{'Orientation'} == 1);
		}
		if($rotate){
			$imagelol->rotate_image($jpg_dst, $jpg_dst)
				or return error_log("Could not rotate image '$jpg_dst'.");
		}
		
		# If strict filename is in place, we don't want to add it to the DB
		# We've done all of the above, so that we still have the image in the archive
		# but since it will break the logic of the DB, we won't add it there
		if ($config{div}->{strict_filename}){
			unless($image->{filename} =~ m/^$config{regex}->{strict_filename}/i && 
				$image->{filename} =~ m/^.+\.($config{div}->{image_filenames})$/i){
				if (-e $image->{org_src}){
					# The file actually exists, lets delete it.
					$imagelol->system_rm($image->{org_src})
						or return error_log("Could not delete import image '$image->{org_src}'.");
				}
				log_it("Strict filenames enabled. Image '$image->{filename}' does not conform with this -- not adding to DB.");
				return 1; # return gracefullly -- this is not a fail
			}
		}
		
		# Add to image hash, so we can add to DB later on
		(my $imagenumber = $image->{pretty_filename}) =~ s/^$config{regex}->{imagenumber}$/$2/i;
		my %image_info : shared = (
			image_file => $image->{pretty_filename},
			original_file => $image_dst_file,
			preview_file => $jpg_dst,
			import_file => $image->{org_src},
			full_date => $full_date,
			category => $category,
			imagenumber => $imagenumber,
		);
		$images{$image->{org_src}} = \%image_info;
		
		# Done
		return 1;
	} else {
		return error_log("Image ($image->{filename}) didn't match our criterias. Nothing done.");
	}
}

# Copy images
sub process_images{
	while (my $image = $imageq->dequeue()){
		last if ($image eq 'DONE');	# all done
		
		if(process_image($image)){
			log_it("Successfully processed image $image->{filename}.");
		} else {
			log_it("Something went wrong when processing image $image->{filename}.")
		}
	}
	
  	# detach thread -- we're done
	threads->detach;
}

# Add images to database
sub db_add_images{
	foreach my $imageid ( keys %images ){
		
		
		if($imagelol->add_image(	$images{$imageid}->{image_file},
						$images{$imageid}->{original_file},
						$images{$imageid}->{full_date},
						$images{$imageid}->{category},
						$images{$imageid}->{preview_file},
						$images{$imageid}->{imagenumber},
						$desc )){
			# All OK
			log_it("Added image '$images{$imageid}->{image_file}' to the DB.");
			
			# At this point we successfully copied the image, extracted the preview
			# and added it to the database. We should now delete the temporary file from 
			# the import directory.
			if (-e $images{$imageid}->{import_file}){
				# The file actually exists, lets delete it.
				$imagelol->system_rm($images{$imageid}->{import_file}) or return error_log("Could not delete import image '$images{$imageid}->{import_file}'.");
			} else {
				# File does not exist... means it's been removed after it was
				# read, and before we are at this point. Should not happen.
				error_log("Import-file '$images{$imageid}->{import_file}' is gone. Cannot delete. This should not happen.");
			}
		} else {
			# Something went wrong adding
			return error_log("Could not add image '$images{$imageid}->{image_file}' to the DB.");
			
			# TODO: do something about this -- print report at end of run or whatever
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

# Find all images, add to queue
find_images();

# Let the threads know when they're done
$imageq->enqueue("DONE") for (1..$max_threads);

# Start processing the queue
threads->create("process_images") for (1..$max_threads);

# Wait till all threads is done
sleep 5 while (threads->list(threads::running));

# Add images to database
db_add_images();

$imagelol->disconnect();

# How long did we run
my $runtime = time() - $time_start;
log_it("Took $runtime seconds to complete.");

__DATA__
Do not remove. Makes sure flock() code above works as it should.
