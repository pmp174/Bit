//
//  FilterChain+Shader.swift
//  OpenEmuShaders
//
//  Created by Stuart Carnie on 19/10/2022.
//  Copyright © 2022 OpenEmu. All rights reserved.
//

import Foundation
@_implementationOnly import os.log
@_implementationOnly import QuartzCore

public extension FilterChain {
    func setShader(fromURL url: URL, options shaderOptions: ShaderCompilerOptions) throws {
        os_log("Loading shader from '%{public}@'", log: .default, type: .info, url.absoluteString)
        
        let start = CACurrentMediaTime()
        
        let shader = try SlangShader(fromURL: url)
        os_log("SlangShader parsed: %{public}d passes", log: .default, type: .info, shader.passes.count)
        
        let compiler = ShaderPassCompiler(shaderModel: shader)
        
        os_log("Compiling shader from '%{public}@'", log: .default, type: .info, url.absoluteString)
        
        let compiled = try compiler.compile(options: shaderOptions)
        os_log("Shader compiled: %{public}d passes, language version: %{public}@", log: .default, type: .info, compiled.passes.count, String(describing: compiled.languageVersion))
        
        let sc = FileCompiledShaderContainer.Decoder(shader: compiled)
        
        let end = CACurrentMediaTime() - start
        os_log("Shader compilation completed in %{xcode:interval}f seconds", log: .default, type: .info, end)
        
        try setCompiledShader(sc)
        os_log("setCompiledShader succeeded, hasShader=%{public}@", log: .default, type: .info, hasShader ? "true" : "false")
    }
}
