// MangaShelf's iOS implementation for the source-built OpenJDK NIO probe.
// This source is not included in the production reader before device validation.
#if defined(__IOS__)
#if !__has_feature(objc_arc)
#error MangaShelf iOS file type probing requires ARC
#endif

#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdint.h>
#include <stdlib.h>
#include "jni.h"
#include "jni_util.h"

jstring msl_ios_filetype_probe(JNIEnv *env, jstring extension) {
    if (!extension || (*env)->ExceptionCheck(env)) return NULL;
    @autoreleasepool {
        @try {
            jsize length = (*env)->GetStringLength(env, extension);
            if ((*env)->ExceptionCheck(env)) return NULL;
            const jchar *characters = (*env)->GetStringChars(env, extension, NULL);
            if (!characters) return NULL;
            NSString *name = nil;
            @try {
                name = [[NSString alloc] initWithCharacters:(const unichar *)characters length:(NSUInteger)length];
            } @finally {
                (*env)->ReleaseStringChars(env, extension, characters);
            }
            if ((*env)->ExceptionCheck(env)) return NULL;
            if (!name) {
                JNU_ThrowOutOfMemoryError(env, "Could not copy filename extension");
                return NULL;
            }
            if (name.length == 0) return NULL;
            NSString *mime = [UTType typeWithFilenameExtension:name].preferredMIMEType;
            if (!mime) return NULL;
            NSUInteger count = mime.length;
            if (count > INT32_MAX || count > SIZE_MAX / sizeof(jchar)) {
                JNU_ThrowOutOfMemoryError(env, "MIME type exceeds JNI string bounds");
                return NULL;
            }
            if (count == 0) {
                jchar empty = 0;
                return (*env)->NewString(env, &empty, 0);
            }
            jchar *buffer = malloc(count * sizeof(jchar));
            if (!buffer) {
                JNU_ThrowOutOfMemoryError(env, "Could not copy MIME type");
                return NULL;
            }
            jstring result = NULL;
            @try {
                [mime getCharacters:(unichar *)buffer range:NSMakeRange(0, count)];
                result = (*env)->NewString(env, buffer, (jsize)count);
            } @finally {
                free(buffer);
            }
            return result;
        } @catch (NSException *failure) {
            // Objective-C exceptions must not unwind into the Java VM.
            if (!(*env)->ExceptionCheck(env)) {
                if ([failure.name isEqualToString:NSMallocException]) {
                    JNU_ThrowOutOfMemoryError(env, "File type lookup allocation failed");
                } else {
                    JNU_ThrowByName(env, "java/lang/IllegalArgumentException", "Invalid filename extension");
                }
            }
            return NULL;
        }
    }
}
#endif
