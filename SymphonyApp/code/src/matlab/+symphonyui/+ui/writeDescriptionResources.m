function writeDescriptionResources(persistentEntity, descriptionInstance)
    %WRITEDESCRIPTIONRESOURCES  Write description resources in Symphony2-compatible format.
    %
    %   persistentEntity: C# IPersistentEntity (source, epoch group, etc.)
    %   descriptionInstance: MATLAB description object (SourceDescription, EpochGroupDescription, etc.)
    %
    %   Writes:
    %     - 'descriptionType' resource: serialized class name (getByteStreamFromArray)
    %     - 'propertyDescriptors' resource: serialized PropertyDescriptor array
    %     - Property values as HDF5 attributes
    %     - Any additional resources from the description
    %
    %   This format is backward-compatible with Symphony2's Entity.newEntity().

    if isempty(persistentEntity) || isempty(descriptionInstance)
        return;
    end

    try
        % 1. Write the description type (class name) as a serialized resource
        descType = class(descriptionInstance);
        typeBytes = getByteStreamFromArray(descType);
        try
            persistentEntity.AddResource('com.mathworks.byte-stream', 'descriptionType', typeBytes);
        catch addEx
            % Resource might already exist — try removing first
            try
                persistentEntity.RemoveResource('descriptionType');
                persistentEntity.AddResource('com.mathworks.byte-stream', 'descriptionType', typeBytes);
            catch
                fprintf(2, 'writeDescriptionResources: failed to write descriptionType: %s\n', addEx.message);
            end
        end

        % 2. Get property descriptors from the description
        descriptors = descriptionInstance.getPropertyDescriptors();

        % 3. Write each property value as an HDF5 attribute
        for i = 1:numel(descriptors)
            try
                val = descriptors(i).value;
                % Convert to a type the C# AddProperty can handle
                if iscell(val)
                    val = strjoin(cellfun(@char, val, 'UniformOutput', false), ';');
                elseif isnumeric(val) || islogical(val)
                    val = num2str(val);
                else
                    val = char(string(val));
                end
                persistentEntity.AddProperty(descriptors(i).name, val);
            catch
                % Property might already exist — skip
            end
        end

        % 4. Write the full PropertyDescriptor array as a serialized resource
        %    This is what Symphony2's DataManagerPresenter reads.
        try
            descBytes = getByteStreamFromArray(descriptors);
            try
                persistentEntity.AddResource('com.mathworks.byte-stream', 'propertyDescriptors', descBytes);
            catch
                try
                    persistentEntity.RemoveResource('propertyDescriptors');
                    persistentEntity.AddResource('com.mathworks.byte-stream', 'propertyDescriptors', descBytes);
                catch
                end
            end
        catch serEx
            fprintf(2, 'writeDescriptionResources: failed to serialize propertyDescriptors: %s\n', serEx.message);
        end

        % 5. Write any additional resources from the description
        try
            names = descriptionInstance.getResourceNames();
            for i = 1:numel(names)
                name = names{i};
                try
                    resource = descriptionInstance.getResource(name);
                    resBytes = getByteStreamFromArray(resource);
                    try
                        persistentEntity.AddResource('com.mathworks.byte-stream', name, resBytes);
                    catch
                        try
                            persistentEntity.RemoveResource(name);
                            persistentEntity.AddResource('com.mathworks.byte-stream', name, resBytes);
                        catch
                        end
                    end
                catch
                end
            end
        catch
        end

        fprintf('writeDescriptionResources: wrote %d descriptors for %s\n', numel(descriptors), descType);
    catch ex
        fprintf(2, 'writeDescriptionResources: %s\n', ex.message);
    end
end
