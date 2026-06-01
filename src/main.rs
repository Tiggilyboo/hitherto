use ash::{vk, Device, Entry, Instance};
use std::ffi::CStr;
use std::fs;
use std::process::Termination;

#[repr(i32)]
#[derive(Debug)]
enum ExitCode {
    Vulkan(vk::Result),
    NoVulkanComputeDevice,
    KernelLoadFailed(String),
}

impl std::fmt::Display for ExitCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExitCode::Vulkan(code) => write!(f, "Vulkan error: {:?}", code),
            ExitCode::NoVulkanComputeDevice => write!(f, "No vulkan compute device found"),
            ExitCode::KernelLoadFailed(path) => write!(f, "Failed to load kernel: {}", path),

        }
    }
}

impl std::error::Error for ExitCode {}

impl From<vk::Result> for ExitCode {
    fn from(code: vk::Result) -> Self {
        ExitCode::Vulkan(code)
    }
}

impl Termination for ExitCode {
    fn report(self) -> std::process::ExitCode {
        let code = match self {
            ExitCode::Vulkan(e) => e.as_raw(),
            ExitCode::NoVulkanComputeDevice => vk::Result::ERROR_UNKNOWN.as_raw(),
            ExitCode::KernelLoadFailed(_) => vk::Result::ERROR_UNKNOWN.as_raw(),

        };
        std::process::exit(code)
    }
}

/// Vulkan device context: instance, physical device, logical device, compute queue.
struct VulkanContext {
    instance: Instance,
    physical_device: vk::PhysicalDevice,
    device: Device,
    queue: vk::Queue,
    queue_family_index: u32,
}

/// GPU buffer with backing memory.
struct Buffer {
    buffer: vk::Buffer,
    memory: vk::DeviceMemory,
    size: vk::DeviceSize,
}



impl VulkanContext {
    fn new() -> Result<Self, ExitCode> {
        let entry = Entry::linked();

        let version = unsafe { entry.try_enumerate_instance_version() };
        let api_version = match version {
            Ok(Some(v)) => v,
            Ok(None) => vk::make_api_version(0, 1, 0, 0),
            Err(e) => return Err(e.into()),
        };

        let app_info = vk::ApplicationInfo {
            api_version,
            ..Default::default()
        };
        let create_info = vk::InstanceCreateInfo {
            p_application_info: &app_info,
            ..Default::default()
        };

        let instance = unsafe { entry.create_instance(&create_info, None)? };

        // Enumerate physical devices and find one with a compute queue
        let physical_devices = unsafe { instance.enumerate_physical_devices()? };
        let (physical_device, queue_family_index) = physical_devices
            .iter()
            .find_map(|&pd| {
                let queue_families =
                    unsafe { instance.get_physical_device_queue_family_properties(pd) };
                let idx = queue_families
                    .iter()
                    .position(|q| q.queue_flags.contains(vk::QueueFlags::COMPUTE))?
                    as u32;
                Some((pd, idx))
            })
            .ok_or(ExitCode::NoVulkanComputeDevice)?;

        // Create logical device
        let queue_priority = 1.0f32;
        let queue_create_info = vk::DeviceQueueCreateInfo {
            queue_family_index,
            queue_count: 1,
            p_queue_priorities: std::slice::from_ref(&queue_priority).as_ptr(),
            ..Default::default()
        };
        let queue_create_infos = [queue_create_info];
        let device_create_info = vk::DeviceCreateInfo {
            queue_create_info_count: 1,
            p_queue_create_infos: queue_create_infos.as_ptr(),
            ..Default::default()
        };
        let device =
            unsafe { instance.create_device(physical_device, &device_create_info, None)? };

        let queue = unsafe { device.get_device_queue(queue_family_index, 0) };

        Ok(VulkanContext {
            instance,
            physical_device,
            device,
            queue,
            queue_family_index,
        })
    }
}

/// Find a memory type index that satisfies `type_filter` bitmask and `properties` flags.
fn find_memory_type(
    ctx: &VulkanContext,
    type_filter: u32,
    properties: vk::MemoryPropertyFlags,
) -> Result<u32, ExitCode> {
    let mem_props = unsafe { ctx.instance.get_physical_device_memory_properties(ctx.physical_device) };
    for (i, mt) in mem_props.memory_types.iter().enumerate() {
        if (type_filter & (1 << i)) != 0 && mt.property_flags.contains(properties) {
            return Ok(i as u32);
        }
    }
    Err(ExitCode::NoVulkanComputeDevice)
}

/// Create a buffer, allocate memory, and bind it.
fn create_buffer(
    ctx: &VulkanContext,
    size: vk::DeviceSize,
    usage: vk::BufferUsageFlags,
    properties: vk::MemoryPropertyFlags,
) -> Result<Buffer, ExitCode> {
    let buffer_info = vk::BufferCreateInfo {
        size,
        usage,
        ..Default::default()
    };
    let buffer = unsafe { ctx.device.create_buffer(&buffer_info, None)? };

    let mem_reqs = unsafe { ctx.device.get_buffer_memory_requirements(buffer) };
    let type_index = find_memory_type(ctx, mem_reqs.memory_type_bits, properties)?;

    let alloc_info = vk::MemoryAllocateInfo {
        allocation_size: mem_reqs.size,
        memory_type_index: type_index,
        ..Default::default()
    };
    let memory = unsafe { ctx.device.allocate_memory(&alloc_info, None)? };
    unsafe { ctx.device.bind_buffer_memory(buffer, memory, 0)? };

    Ok(Buffer {
        buffer,
        memory,
        size,
    })
}

/// Load SPIR-V binary from a file.
fn load_spirv(path: &str) -> Result<Vec<u32>, ExitCode> {
    let bytes = fs::read(path).map_err(|_| ExitCode::KernelLoadFailed(path.to_string()))?;
    if bytes.len() % 4 != 0 {
        return Err(ExitCode::KernelLoadFailed(path.to_string()));
    }
    let words: Vec<u32> = bytes
        .chunks_exact(4)
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    Ok(words)
}

fn main() -> Result<(), ExitCode> {
    let ctx = VulkanContext::new()?;

    // --- Load SPIR-V kernel ---
    let kernel_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "kernels/compute.spv".to_string());
    let spirv = load_spirv(&kernel_path)?;

    // --- Create shader module ---
    let shader_module = unsafe {
        ctx.device.create_shader_module(
            &vk::ShaderModuleCreateInfo {
                code_size: spirv.len() * 4,
                p_code: spirv.as_ptr(),
                ..Default::default()
            },
            None,
        )?
    };

    // --- Create descriptor set layout (2 storage buffer bindings) ---
    let bindings = [
        vk::DescriptorSetLayoutBinding {
            binding: 0,
            descriptor_type: vk::DescriptorType::STORAGE_BUFFER,
            descriptor_count: 1,
            stage_flags: vk::ShaderStageFlags::COMPUTE,
            ..Default::default()
        },
        vk::DescriptorSetLayoutBinding {
            binding: 1,
            descriptor_type: vk::DescriptorType::STORAGE_BUFFER,
            descriptor_count: 1,
            stage_flags: vk::ShaderStageFlags::COMPUTE,
            ..Default::default()
        },
    ];
    let desc_set_layout = unsafe {
        ctx.device.create_descriptor_set_layout(
            &vk::DescriptorSetLayoutCreateInfo {
                binding_count: bindings.len() as u32,
                p_bindings: bindings.as_ptr(),
                ..Default::default()
            },
            None,
        )?
    };

    // --- Create pipeline layout ---
    let pipeline_layout = unsafe {
        let layouts = [desc_set_layout];
        ctx.device.create_pipeline_layout(
            &vk::PipelineLayoutCreateInfo {
                set_layout_count: 1,
                p_set_layouts: layouts.as_ptr(),
                ..Default::default()
            },
            None,
        )?
    };

    // --- Create compute pipeline ---
    let entry_point = CStr::from_bytes_with_nul(b"main\0").unwrap();
    let stage_info = vk::PipelineShaderStageCreateInfo {
        stage: vk::ShaderStageFlags::COMPUTE,
        module: shader_module,
        p_name: entry_point.as_ptr(),
        ..Default::default()
    };
    let pipeline_create_info = vk::ComputePipelineCreateInfo {
        stage: stage_info,
        layout: pipeline_layout,
        ..Default::default()
    };
    let pipeline = unsafe {
        let pipelines = ctx.device.create_compute_pipelines(
            vk::PipelineCache::null(),
            &[pipeline_create_info],
            None,
        ).map_err(|(_, e)| ExitCode::Vulkan(e))?;
        pipelines.into_iter().next().unwrap()
    };

    // --- Create buffers ---
    let elem_count: u32 = 256;
    let buf_size = (elem_count * std::mem::size_of::<f32>() as u32) as vk::DeviceSize;

    let input_buf = create_buffer(
        &ctx,
        buf_size,
        vk::BufferUsageFlags::STORAGE_BUFFER,
        vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_COHERENT,
    )?;

    let output_buf = create_buffer(
        &ctx,
        buf_size,
        vk::BufferUsageFlags::STORAGE_BUFFER,
        vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_COHERENT,
    )?;

    // --- Write input data ---
    let input_ptr = unsafe {
        ctx.device.map_memory(
            input_buf.memory,
            0,
            input_buf.size,
            vk::MemoryMapFlags::empty(),
        )?
    };
    let input_slice = unsafe {
        std::slice::from_raw_parts_mut(input_ptr as *mut f32, elem_count as usize)
    };
    for (i, val) in input_slice.iter_mut().enumerate() {
        *val = i as f32;
    }

    // --- Create descriptor pool ---
    let pool_sizes = [
        vk::DescriptorPoolSize {
            ty: vk::DescriptorType::STORAGE_BUFFER,
            descriptor_count: 2,
        },
    ];
    let desc_pool = unsafe {
        ctx.device.create_descriptor_pool(
            &vk::DescriptorPoolCreateInfo {
                max_sets: 1,
                pool_size_count: pool_sizes.len() as u32,
                p_pool_sizes: pool_sizes.as_ptr(),
                ..Default::default()
            },
            None,
        )?
    };

    // --- Allocate descriptor set ---
    let desc_set_layouts = [desc_set_layout];
    let desc_set_alloc = vk::DescriptorSetAllocateInfo {
        descriptor_pool: desc_pool,
        descriptor_set_count: 1,
        p_set_layouts: desc_set_layouts.as_ptr(),
        ..Default::default()
    };
    let desc_sets = unsafe { ctx.device.allocate_descriptor_sets(&desc_set_alloc)? };
    let desc_set = desc_sets[0];

    // --- Update descriptor sets ---
    let buffer_infos = [
        vk::DescriptorBufferInfo {
            buffer: input_buf.buffer,
            offset: 0,
            range: vk::WHOLE_SIZE,
        },
        vk::DescriptorBufferInfo {
            buffer: output_buf.buffer,
            offset: 0,
            range: vk::WHOLE_SIZE,
        },
    ];
    let write_desc_sets = [
        vk::WriteDescriptorSet {
            dst_set: desc_set,
            dst_binding: 0,
            descriptor_count: 1,
            descriptor_type: vk::DescriptorType::STORAGE_BUFFER,
            p_buffer_info: &buffer_infos[0],
            ..Default::default()
        },
        vk::WriteDescriptorSet {
            dst_set: desc_set,
            dst_binding: 1,
            descriptor_count: 1,
            descriptor_type: vk::DescriptorType::STORAGE_BUFFER,
            p_buffer_info: &buffer_infos[1],
            ..Default::default()
        },
    ];
    unsafe { ctx.device.update_descriptor_sets(&write_desc_sets, &[]) };

    // --- Create command pool and command buffer ---
    let cmd_pool = unsafe {
        ctx.device.create_command_pool(
            &vk::CommandPoolCreateInfo {
                queue_family_index: ctx.queue_family_index,
                ..Default::default()
            },
            None,
        )?
    };

    let cmd_alloc = vk::CommandBufferAllocateInfo {
        command_pool: cmd_pool,
        level: vk::CommandBufferLevel::PRIMARY,
        command_buffer_count: 1,
        ..Default::default()
    };
    let cmd_buffers = unsafe { ctx.device.allocate_command_buffers(&cmd_alloc)? };
    let cmd_buf = cmd_buffers[0];

    // --- Record commands ---
    unsafe {
        ctx.device.begin_command_buffer(
            cmd_buf,
            &vk::CommandBufferBeginInfo::default(),
        )?;

        ctx.device.cmd_bind_pipeline(
            cmd_buf,
            vk::PipelineBindPoint::COMPUTE,
            pipeline,
        );

        ctx.device.cmd_bind_descriptor_sets(
            cmd_buf,
            vk::PipelineBindPoint::COMPUTE,
            pipeline_layout,
            0,
            &[desc_set],
            &[],
        );

        let group_count = (elem_count + 255) / 256;
        ctx.device.cmd_dispatch(cmd_buf, group_count, 1, 1);

        ctx.device.end_command_buffer(cmd_buf)?;
    };

    // --- Submit and wait ---
    let fence = unsafe {
        ctx.device.create_fence(&vk::FenceCreateInfo::default(), None)?
    };

    let cmd_bufs = [cmd_buf];
    let submit_info = vk::SubmitInfo {
        command_buffer_count: 1,
        p_command_buffers: cmd_bufs.as_ptr(),
        ..Default::default()
    };
    unsafe {
        ctx.device.queue_submit(ctx.queue, &[submit_info], fence)?;
        ctx.device.wait_for_fences(&[fence], true, u64::MAX)?;
    };

    // --- Read back output ---
    let output_ptr = unsafe {
        ctx.device.map_memory(
            output_buf.memory,
            0,
            output_buf.size,
            vk::MemoryMapFlags::empty(),
        )?
    };
    let output_slice = unsafe { std::slice::from_raw_parts(output_ptr as *const f32, elem_count as usize) };

    println!("Input:  {:?}", &input_slice[..8]);
    println!("Output: {:?}", &output_slice[..8]);

    // Verify
    for i in 0..elem_count as usize {
        let expected = i as f32 * 2.0;
        if (output_slice[i] - expected).abs() > 1e-6 {
            eprintln!("Mismatch at {}: got {}, expected {}", i, output_slice[i], expected);
        }
    }
    println!("All {} elements verified.", elem_count);

    // --- Cleanup (Drop handles Vulkan object destruction in reverse order) ---
    unsafe {
        ctx.device.unmap_memory(output_buf.memory);
        ctx.device.unmap_memory(input_buf.memory);
        ctx.device.destroy_fence(fence, None);
        ctx.device.free_command_buffers(cmd_pool, &cmd_buffers);
        ctx.device.destroy_command_pool(cmd_pool, None);
        ctx.device.destroy_descriptor_pool(desc_pool, None);
        ctx.device.destroy_pipeline(pipeline, None);
        ctx.device.destroy_pipeline_layout(pipeline_layout, None);
        ctx.device.destroy_descriptor_set_layout(desc_set_layout, None);
        ctx.device.destroy_shader_module(shader_module, None);
        ctx.device.destroy_buffer(output_buf.buffer, None);
        ctx.device.destroy_buffer(input_buf.buffer, None);
        ctx.device.free_memory(output_buf.memory, None);
        ctx.device.free_memory(input_buf.memory, None);
        ctx.device.destroy_device(None);
        ctx.instance.destroy_instance(None);
    }

    Ok(())
}
