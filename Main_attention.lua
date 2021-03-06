require 'torch'
require 'nn'
require 'cudnn'
require 'optim'
require 'recurrent'
require 'DataProvider'
require 'eladtools'
-------------------------------------------------------

cmd = torch.CmdLine()
cmd:addTime()
cmd:text()
cmd:text('Training recurrent networks to create captions from images')
cmd:text()
cmd:text('==>Options')

cmd:text('===>Data Options')
cmd:option('-shuffle',            false,                       'shuffle training samples')

cmd:text('===>Model And Training Regime')
cmd:option('-model',              'GRU',                       'Model file - must return a model bulider function')
cmd:option('-seqLength',          10,                          'number of timesteps to unroll for')
cmd:option('-embeddingSize',      128,                         'size of word embedding')
cmd:option('-rnnSize',            128,                         'size of rnn hidden layer')
cmd:option('-numLayers',          2,                           'number of layers in the LSTM')
cmd:option('-dropout',            0.5,                         'dropout p value')
cmd:option('-LR',                 1e-3,                        'learning rate')
cmd:option('-LRDecay',            0,                           'learning rate decay (in # samples)')
cmd:option('-weightDecay',        0,                           'L2 penalty on the weights')
cmd:option('-momentum',           0.9,                         'momentum')
cmd:option('-batchSize',          32,                          'batch size')
cmd:option('-decayRate',          0.95,                        'decay rate for rmsprop')
cmd:option('-initWeight',         0.08,                        'uniform weight initialization range')
cmd:option('-optimization',       'adam',                   'optimization method')
cmd:option('-gradClip',           5,                           'clip gradients at this value')
cmd:option('-epoch',              -1,                          'number of epochs to train, -1 for unbounded')

cmd:text('===>Platform Optimization')
cmd:option('-threads',            8,                           'number of threads')
cmd:option('-type',               'cuda',                      'float or cuda')
cmd:option('-devid',              1,                           'device ID (if using CUDA)')
cmd:option('-nGPU',               1,                           'num of gpu devices used')
cmd:option('-bufferSize',         5120,                     'buffer size')
cmd:option('-seed',               123,                         'torch manual random number generator seed')
cmd:option('-constBatchSize',     false,                       'do not allow varying batch sizes')

cmd:text('===>Save/Load Options')
cmd:option('-load',               '',                          'load existing net weights')
cmd:option('-save',               os.date():gsub(' ',''),      'save directory')
cmd:option('-optState',           false,                       'Save optimization state every epoch')
cmd:option('-checkpoint',         0,                           'Save a weight check point every n samples. 0 for off')




opt = cmd:parse(arg or {})
opt.save = paths.concat('./Results', opt.save)
torch.setnumthreads(opt.threads)
torch.manualSeed(opt.seed)
torch.setdefaulttensortype('torch.FloatTensor')
local AllowVarBatch = not opt.constBatchSize


----------------------------------------------------------------------
-- Output files configuration
os.execute('mkdir -p ' .. opt.save)

cmd:log(opt.save .. '/Log.txt', opt)
local netFilename = paths.concat(opt.save, 'Net')
local logFilename = paths.concat(opt.save,'LossRate.log')
local optStateFilename = paths.concat(opt.save,'optState')
local Log = optim.Logger(logFilename)

----------------------------------------------------------------------
local data = require 'Data'
local config = require 'Config'
local normalization = config.Normalization

config.SentenceLength = opt.seqLength
local vocabSize = 0
for _ in pairs(config.Vocab) do vocabSize = vocabSize + 1 end
print('Vocab Size: ' .. vocabSize)
----------------------------------------------------------------------
-- Model + Loss:

local modelConfig = {}
if paths.filep(opt.load) then
    modelConfig = torch.load(opt.load)
    print('==>Loaded Net from: ' .. opt.load)
else
    local rnnTypes = {LSTM = nn.AttentiveLSTM, GRU = nn.AttentiveGRU}
    local rnn = rnnTypes[opt.model]
    modelConfig.recurrent = rnn(opt.embeddingSize, opt.rnnSize, opt.embeddingSize, 7*7)
end

local trainRegime = modelConfig.regime
local recurrent = modelConfig.recurrent

local textEmbedder = nn.Sequential()
textEmbedder:add(nn.LookupTable(vocabSize, opt.embeddingSize)):add(nn.SplitTable(1,2))

local imageEmbedder = nn.Sequential()
imageEmbedder:add(cudnn.SpatialConvolution(config.NumFeatsCNN, opt.embeddingSize, 1, 1))
imageEmbedder:add(nn.ReLU())
imageEmbedder:add(nn.View(opt.embeddingSize ,-1):setNumInputDims(3))
imageEmbedder:add(nn.Transpose({2,3}))

local embedder = nn.Sequential():add(imageEmbedder):add(textEmbedder)
local classifier = nn.Linear(opt.rnnSize, vocabSize)
local loss = nn.TemporalCriterion(nn.CrossEntropyCriterion())

local cnnModel = torch.load(config.PreTrainedCNN)
local removeAfter = config.FeatLayerCNN
for i = #cnnModel, removeAfter ,-1 do
    cnnModel:remove(i)
end

local model = nn.Sequential():add(embedder):add(recurrent):add(classifier)


local TensorType = 'torch.FloatTensor'



if opt.type =='cuda' then
    require 'cutorch'
    require 'cunn'
    cutorch.setDevice(opt.devid)
    cutorch.manualSeed(opt.seed)
    cnnModel:cuda()
    model:cuda()
    loss = loss:cuda()
    TensorType = 'torch.CudaTensor'


    ---Support for multiple GPUs - currently data parallel scheme
    if opt.nGPU > 1 then
        initState:resize(opt.batchSize / opt.nGPU, stateSize)
        recurrent:setState(initState)
        local net = model
        model = nn.DataParallelTable(1)
        model:add(net, 1)
        for i = 2, opt.nGPU do
            cutorch.setDevice(i)
            model:add(net:clone(), i)  -- Use the ith GPU
        end
        cutorch.setDevice(opt.devid)
    end
end


-- Optimization configuration
local Weights,Gradients = model:getParameters()

local savedModel = {
    textEmbedder = textEmbedder:clone('weight','bias', 'running_mean', 'running_std'),
    imageEmbedder = imageEmbedder:clone('weight','bias', 'running_mean', 'running_std'),
    classifier = classifier:clone('weight','bias', 'running_mean', 'running_std'),
    recurrent = recurrent:clone('weight','bias', 'running_mean', 'running_std')
}

----------------------------------------------------------------------
print '\n==> Network'
print(model)
print('\n==>' .. Weights:nElement() ..  ' Parameters')

print '\n==> Loss'
print(loss)

------------------Optimization Configuration--------------------------

local optimState = {
    learningRate = opt.LR,
    momentum = opt.momentum,
    weightDecay = opt.weightDecay,
    learningRateDecay = opt.LRDecay,
    alpha = opt.decayRate
}

local optimizer = Optimizer{
    Model = model,
    Loss = loss,
    OptFunction = _G.optim[opt.optimization],
    OptState = optimState,
    Parameters = {Weights, Gradients},
    Regime = trainRegime,
    GradRenorm  = opt.gradClip
}

----------------------------------------------------------------------

local function saveModel(fn)
    torch.save(fn,
    {
        textEmbedder = savedModel.textEmbedder:clone():float(),
        imageEmbedder = savedModel.imageEmbedder:clone():float(),
        classifier = savedModel.classifier:clone():float(),
        recurrent = savedModel.recurrent:clone():float(),
        inputSize = config.InputSize,
        stateSize = stateSize,
        vocab = config.Vocab,
        decoder = data.decoder
    })
    collectgarbage()
end

----------------------------------------------------------------------
local function Forward(DB, train)

    local SizeData = math.floor(DB:size()/opt.batchSize)*opt.batchSize
    local dataIndices = torch.range(1, SizeData, opt.bufferSize):long()
    if train and opt.shuffle then --shuffle batches from LMDB
        dataIndices = dataIndices:index(1, torch.randperm(dataIndices:size(1)):long())
    end

    local numBuffers = 2
    local currBuffer = 1
    local BufferSources = {}
    for i=1,numBuffers do
        BufferSources[i] = DataProvider.Container{
            Source = {torch.ByteTensor(),torch.IntTensor()}
        }
    end


    local currBatch = 1

    local BufferNext = function()
        currBuffer = currBuffer%numBuffers +1
        if currBatch > dataIndices:size(1) then BufferSources[currBuffer] = nil return end
        local sizeBuffer = math.min(opt.bufferSize, SizeData - dataIndices[currBatch]+1)
        BufferSources[currBuffer].Data:resize(sizeBuffer ,unpack(config.InputSize))
        BufferSources[currBuffer].Labels:resize(sizeBuffer, opt.seqLength)
        DB:asyncCacheSeq(config.Key(dataIndices[currBatch]), sizeBuffer, BufferSources[currBuffer].Data, BufferSources[currBuffer].Labels)
        currBatch = currBatch + 1
    end

    local MiniBatch = DataProvider.Container{
        Name = 'GPU_Batch',
        MaxNumItems = opt.batchSize,
        Source = BufferSources[currBuffer],
        TensorType = TensorType
    }

    local yt = MiniBatch.Labels
    local y = torch.Tensor()
    local images = MiniBatch.Data
    local NumSamples = 0
    local lossVal = 0
    local currLoss = 0
    local captionModel = nn.Sequential():add(recurrent):add(nn.JoinTable(1,2,'caption'):type(TensorType)):add(classifier):add(nn.View(opt.batchSize, opt.seqLength, vocabSize))
    captionModel:sequence()

    BufferNext()

    while NumSamples < SizeData do
        DB:synchronize()
        MiniBatch:reset()
        MiniBatch.Source = BufferSources[currBuffer]
        if train and opt.shuffle then MiniBatch.Source:shuffleItems() end
        BufferNext()

        while MiniBatch:getNextBatch() do
            model:zeroState()
            if #normalization>0 then MiniBatch:normalize(unpack(normalization)) end
            local imageRep = imageEmbedder:forward(cnnModel:forward(images))
            local text = textEmbedder:forward(yt:narrow(2, 1, opt.seqLength - 1))
            local input = {}
            input[1] = {torch.CudaTensor(opt.batchSize, opt.embeddingSize):zero(), imageRep}
            for i=2,opt.seqLength do
                input[i] = {text[i-1], imageRep}
            end
            t=torch.tic()
            y = captionModel:forward(input)
            --print(torch.tic()-t)
            currLoss = loss:forward(y,yt)
          --  print(currLoss)
            if train then

                local f_eval = function()
                    local dE_dy = loss:backward(y,yt)
                    local dE_dCap = captionModel:backward(input, dE_dy)
                    local dE_dEmb = {}
                    local dE_dimg = dE_dCap[1][2]
                    for i=1, opt.seqLength - 1 do
                        dE_dEmb[i] = dE_dCap[i+1][1]
                        dE_dimg = dE_dimg + dE_dCap[i+1][2]
                    end
                    textEmbedder:backward(yt:narrow(2, 1, opt.seqLength - 1), dE_dEmb)
                     imageEmbedder:backward(cnnModel.output, dE_dimg)
                    --Gradient clipping (actually normalizing)
                    local norm = Gradients:norm()
                    if norm > 5 then
                        local shrink = 5 / norm
                        Gradients:mul(shrink)
                    end
                    return currLoss, Gradients
                end

                _G.optim[opt.optimization](f_eval, Weights, optimState)
            end
        lossVal = currLoss / opt.seqLength + lossVal
        NumSamples = NumSamples + opt.batchSize
        xlua.progress(NumSamples, SizeData)
    end
  end

    xlua.progress(NumSamples, SizeData)
    return(lossVal/math.ceil(SizeData/opt.batchSize))
end

------------------------------

local function Train(data)
    model:training()
    embedder:training()
    return Forward(data, true)
end

local function Evaluate(data)
    model:evaluate()
    embedder:evaluate()
    return Forward(data,  false)
end

data.ValDB:threads()
data.TrainDB:threads()

local decreaseLR = EarlyStop(1)
local stopTraining = EarlyStop(5, opt.epoch)
local epoch = 1

repeat
    local ErrTrain, LossTrain
    print('\nEpoch ' .. epoch ..'\n')
    optimizer:updateRegime(epoch, true)
    LossTrain = Train(data.TrainDB)
    saveModel(netFilename .. '_' .. epoch .. '.t7')
    if opt.optState then
        torch.save(optStateFilename .. '_epoch_' .. epoch .. '.t7', optimState)
    end
    print('\nTraining Perplexity: ' .. torch.exp(LossTrain))

    local LossVal = Evaluate(data.ValDB)

    print('\nValidation Perplexity: ' .. torch.exp(LossVal))


    if not opt.testonly then
        Log:add{['Training Perplexity']= torch.exp(LossTrain), ['Validation Perplexity'] = torch.exp(LossVal)}
        Log:style{['Training Perplexity'] = '-', ['Validation Perplexity'] = '-'}
        Log:plot()
    end
    if opt.shuffle then
        data.trainingData:shuffleItems()
    end
    epoch = epoch + 1

    if decreaseLR:update(LossVal) then
        optimState.learningRate = optimState.learningRate / 1.5
        print("Learning Rate decreased to: " .. optimState.learningRate)
        decreaseLR:reset()
    end

until stopTraining:update(LossVal)

local lowestLoss, bestIteration = stopTraining:lowest()

print("Best Iteration was " .. bestIteration .. ", With a validation loss of: " .. lowestLoss)
