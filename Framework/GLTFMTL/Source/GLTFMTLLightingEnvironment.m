//
//  Copyright (c) 2017 Warren Moore. All rights reserved.
//
//  Permission to use, copy, modify, and distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
//  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
//  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

#import "GLTFMTLLightingEnvironment.h"

@import MetalKit;

@interface GLTFMTLLightingEnvironment ()
@property (nonatomic, strong) id<MTLComputePipelineState> brdfComputePipeline;
@end

@implementation GLTFMTLLightingEnvironment

- (instancetype)initWithDiffuseCubeURL:(NSURL *)diffuseCubeURL
                      specularCubeURLs:(NSArray<NSURL *> *)specularCubeURLs
                                device:(id<MTLDevice>)device
                                 error:(NSError **)error
{
    if ((self = [super init])) {
        NSError *internalError = nil;
        
        id<MTLCommandQueue> commandQueue = [device newCommandQueue];
        
        id<MTLLibrary> library = [device newDefaultLibrary];
        id<MTLFunction> brdfFunction = [library newFunctionWithName:@"integrate_brdf"];
        _brdfComputePipeline = [device newComputePipelineStateWithFunction:brdfFunction error:&internalError];
        if (_brdfComputePipeline == nil) {
            if (error) {
                *error = internalError;
            }
            return nil;
        }
        
        MTKTextureLoader *textureLoader = [[MTKTextureLoader alloc] initWithDevice:device];
        
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
        
        id options = @{ MTKTextureLoaderOptionOrigin : MTKTextureLoaderOriginTopLeft,
                        MTKTextureLoaderOptionSRGB : @(NO)
                      };

        id<MTLTexture> diffuseStrip = [textureLoader newTextureWithContentsOfURL:diffuseCubeURL options:options error:&internalError];
        if (diffuseStrip == nil) {
            if (error != nil) {
                *error = internalError;
            }
            return nil;
        }
        
        int diffuseCubeSize = (int)[diffuseStrip width];
        
        MTLTextureDescriptor *cubeDescriptor = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                     size:diffuseCubeSize
                                                                                                mipmapped:NO];
        
        _diffuseCube = [device newTextureWithDescriptor:cubeDescriptor];
        
        for (int i = 0; i < 6; ++i) {
            [blitEncoder copyFromTexture:diffuseStrip
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, i * diffuseCubeSize, 0)
                              sourceSize:MTLSizeMake(diffuseCubeSize, diffuseCubeSize, 1)
                               toTexture:_diffuseCube
                        destinationSlice:i
                        destinationLevel:0
                       destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
        
        int specularMipLevel = 0;
        int specularCubeSize = 0;
        for (int i = 0; i < specularCubeURLs.count; ++i) {
            id<MTLTexture> specularStrip = [textureLoader newTextureWithContentsOfURL:specularCubeURLs[i]
                                                                              options:options
                                                                                error:&internalError];
            
            if (specularStrip == nil) {
                if (error != nil) {
                    *error = internalError;
                }
                return nil;
            }
            
            if (specularCubeSize == 0) {
                specularCubeSize = (int)[specularStrip width];
                MTLTextureDescriptor *cubeDescriptor = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                             size:specularCubeSize
                                                                                                        mipmapped:YES];
                cubeDescriptor.mipmapLevelCount = [specularCubeURLs count];
                _specularCube = [device newTextureWithDescriptor:cubeDescriptor];
            }
            
            for (int i = 0; i < 6; ++i) {
                [blitEncoder copyFromTexture:specularStrip
                                 sourceSlice:0
                                 sourceLevel:0
                                sourceOrigin:MTLOriginMake(0, i * specularCubeSize, 0)
                                  sourceSize:MTLSizeMake(specularCubeSize, specularCubeSize, 1)
                                   toTexture:_specularCube
                            destinationSlice:i
                            destinationLevel:specularMipLevel
                           destinationOrigin:MTLOriginMake(0, 0, 0)];
            }
            
            specularCubeSize = specularCubeSize / 2;
            ++specularMipLevel;
        }
        
        [blitEncoder endEncoding];

        [self generateBRDFLookupWithSize:CGSizeMake(256, 256) commandBuffer:commandBuffer device:device];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
    }
    
    return self;
}

- (void)generateBRDFLookupWithSize:(CGSize)size commandBuffer:(id<MTLCommandBuffer>)commandBuffer device:(id<MTLDevice>)device {
    
    MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                                                           width:size.width
                                                                                          height:size.height
                                                                                       mipmapped:NO];
    textureDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id <MTLTexture> lookupTexture = [device newTextureWithDescriptor:textureDesc];
    
    id<MTLComputeCommandEncoder> commandEncoder = [commandBuffer computeCommandEncoder];
    [commandEncoder setComputePipelineState:_brdfComputePipeline];
    [commandEncoder setTexture:lookupTexture atIndex:0];
    MTLSize threadsPerThreadgroup = MTLSizeMake(16, 16, 1);
    MTLSize threadgroups = MTLSizeMake(size.width / threadsPerThreadgroup.width, size.height / threadsPerThreadgroup.height, 1);
    [commandEncoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerThreadgroup];
    [commandEncoder endEncoding];
    _brdfLUT = lookupTexture;
}

@end
