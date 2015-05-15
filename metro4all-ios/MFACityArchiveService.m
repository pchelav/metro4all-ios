//
//  MFACityArchiveService.m
//  metro4all-ios
//
//  Created by Maxim Smirnov on 07.03.15.
//  Copyright (c) 2015 Maxim Smirnov. All rights reserved.
//

#import <AFNetworking/AFNetworking.h>
#import <SSZipArchive/SSZipArchive.h>
#import <ReactiveCocoa/ReactiveCocoa.h>

#import "MFACityArchiveService.h"
#import "NSDictionary+CityMeta.h"

@interface MFACityArchiveService () <NSURLSessionDownloadDelegate, SSZipArchiveDelegate>

@property (nonatomic, strong) NSURL *baseURL;
@property (nonatomic, strong) MFACityMeta *selectedCityMeta;

@property (nonatomic, copy) void (^completionBlock)(NSString *path, NSError *error);

@property (nonatomic, strong) RACSubject *downloadProgressSignal;

@end

@implementation MFACityArchiveService

- (instancetype)initWithBaseURL:(NSURL *)baseUrl
{
    self = [super init];
    if (self) {
        self.baseURL = baseUrl;
    }
    
    return self;
}

- (void)loadCitiesWithCompletion:(void (^)(NSArray *citiesMeta))completionBlock;
{
    AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    NSURL *metaURL = [NSURL URLWithString:@"meta.json" relativeToURL:self.baseURL];
    NSURLRequest *request = [NSURLRequest requestWithURL:metaURL];

    id successBlock = ^(AFHTTPRequestOperation *operation, id responseObject) {
        NSLog(@"Successfully loaded meta.json");
        
        NSArray *sorted = [responseObject[@"packages"] sortedArrayUsingComparator:^NSComparisonResult(MFACityMeta *city1, MFACityMeta *city2) {
            return [city1.localizedName compare:city2.localizedName];
        }];
        
        NSURL *metaJsonFileURL = [MFACityMeta metaJsonFileURL];
        
        // save json for future use
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:responseObject options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToURL:metaJsonFileURL options:0 error:nil];
        
        if (completionBlock) {
            completionBlock(sorted);
        }
    };
    
    AFHTTPRequestOperation *op = [manager HTTPRequestOperationWithRequest:request
                                     success:successBlock
                                     failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                                         NSLog(@"Failed to get meta.json: %@", error);
                                        
                                         if (completionBlock) {
                                             completionBlock(nil);
                                         }
                                     }];
    
    [op start];
}

- (RACSignal *)getCityFilesForMetadata:(NSDictionary *)cityMeta completion:(void (^)(NSString *path, NSError *error))completion {
    self.selectedCityMeta = cityMeta;
    self.completionBlock = completion;
    
    self.downloadProgressSignal = [RACSubject subject];
    
    NSURL *unzippedPath = [cityMeta filesDirectory];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:unzippedPath.path]) {
        
        // download archive with city data
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                              delegate:self
                                                         delegateQueue:[[NSOperationQueue alloc] init]];
        
        NSURL *archiveURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@.zip", cityMeta[@"path"]] relativeToURL:self.baseURL];
        [[session downloadTaskWithURL:archiveURL] resume];
    }
    else {
        // don't download files again
        self.completionBlock = nil;
        completion(unzippedPath.path, nil);
    }
    
    return self.downloadProgressSignal;
}

#pragma mark - NSURLSession Delegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
    NSLog(@"Successfully loaded zip for %@ to %@", self.selectedCityMeta[@"name"], location);
    
    NSURL *pathURL = [self.selectedCityMeta filesDirectory];
    
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[[[pathURL filePathURL] absoluteURL] path]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    
    if (error) {
        NSLog(@"Failed to create directory structure: %@", error);
        
        self.completionBlock(nil, [NSError errorWithDomain:@"ru.metro4all.zipUnarchiver"
                                                      code:1
                                                  userInfo:@{ NSLocalizedDescriptionKey : @"Failed to create directory structure" }]);
        return;
    }
    
    error = nil;
    [SSZipArchive unzipFileAtPath:[[location filePathURL] path]
                    toDestination:[[pathURL filePathURL] path]
                        overwrite:YES
                         password:nil
                            error:&error
                         delegate:self];
    
    if (error) {
        NSLog(@"Failed to open zip archive: %@", error);
        
        [self.downloadProgressSignal sendCompleted];
        self.completionBlock(nil, [NSError errorWithDomain:@"ru.metro4all.zipUnarchiver"
                                                      code:2
                                                  userInfo:@{ NSLocalizedDescriptionKey : @"Failed to open zip archive" }]);
        return;
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error) {
        NSLog(@"Failed to load zip archive: %@", error);
        
        [self.downloadProgressSignal sendCompleted];
        self.completionBlock(nil, [NSError errorWithDomain:@"ru.metro4all.zipUnarchiver"
                                                      code:3
                                                  userInfo:@{ NSLocalizedDescriptionKey : @"Failed load zip archive" }]);
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
                                 totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    NSLog(@"Downloaded %lld of %lld", totalBytesWritten, totalBytesExpectedToWrite);
    [self.downloadProgressSignal sendNext:@((float)totalBytesWritten/totalBytesExpectedToWrite)];
}

#pragma mark - SSZipArchive Delegate

- (void)zipArchiveDidUnzipArchiveAtPath:(NSString *)path zipInfo:(unz_global_info)zipInfo unzippedPath:(NSString *)unzippedPath
{
    NSLog(@"Successfully unzipped data for %@ into %@", self.selectedCityMeta[@"name"], unzippedPath);
    
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.downloadProgressSignal sendCompleted];
        self.completionBlock(unzippedPath, nil);
    });
}

@end
